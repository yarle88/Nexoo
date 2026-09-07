-- Beneficiarios: las personas que recogen el pedido en Cuba.
--
-- Un comprador suele enviar siempre a los mismos familiares, así que sus datos se
-- guardan una vez en la cuenta y el checkout los rellena. El pedido sigue
-- guardando una copia de esos datos (como hace con el nombre del producto): editar
-- o borrar un beneficiario no reescribe pedidos ya hechos, por eso no hay FK desde
-- `orders`.

create table if not exists public.beneficiaries (
    id              uuid primary key default gen_random_uuid(),
    user_id         uuid not null references auth.users (id) on delete cascade,
    full_name       text not null check (length(trim(full_name)) between 3 and 160),
    -- Carné de identidad cubano: 11 dígitos.
    id_card         text not null check (id_card ~ '^[0-9]{11}$'),
    phone           text not null check (length(trim(phone)) between 6 and 40),
    municipality_id uuid not null references public.municipalities (id) on delete restrict,
    -- Derivados del municipio por el trigger de abajo, como en `businesses`.
    province        text not null references public.provinces (code),
    municipality    text not null,
    address         text not null check (length(trim(address)) between 5 and 500),
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);

create index if not exists ix_beneficiaries_user_id on public.beneficiaries (user_id);

-- El mismo carné no se repite dentro de la libreta de un comprador.
create unique index if not exists ux_beneficiaries_user_id_card
    on public.beneficiaries (user_id, id_card);

drop trigger if exists beneficiaries_touch_updated_at on public.beneficiaries;
create trigger beneficiaries_touch_updated_at
    before update on public.beneficiaries
    for each row execute function public.touch_updated_at();

-- province y municipality se derivan del municipio elegido: no pueden desalinearse.
create or replace function public.beneficiaries_sync_municipality()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_name          text;
    v_province_code text;
begin
    select m.name, m.province_code into v_name, v_province_code
    from public.municipalities m where m.id = new.municipality_id;

    if v_name is null then
        raise exception 'El municipio indicado no existe.' using errcode = '22023';
    end if;

    new.province := v_province_code;
    new.municipality := v_name;
    return new;
end;
$$;

drop trigger if exists beneficiaries_sync_municipality on public.beneficiaries;
create trigger beneficiaries_sync_municipality
    before insert or update of municipality_id on public.beneficiaries
    for each row execute function public.beneficiaries_sync_municipality();

-- Renombrar un municipio también se propaga a los beneficiarios.
create or replace function public.municipalities_propagate_rename()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if new.name is distinct from old.name or new.province_code is distinct from old.province_code then
        update public.businesses
        set municipality = new.name, province = new.province_code
        where municipality_id = new.id;

        update public.beneficiaries
        set municipality = new.name, province = new.province_code
        where municipality_id = new.id;
    end if;
    return new;
end;
$$;

-- RLS: la libreta es privada del comprador. El panel no la lee; lo que necesita
-- para entregar el pedido está copiado en `orders`.
alter table public.beneficiaries enable row level security;

drop policy if exists beneficiaries_owner_all on public.beneficiaries;
create policy beneficiaries_owner_all on public.beneficiaries
    for all to authenticated
    using (user_id = auth.uid()) with check (user_id = auth.uid());

grant select, insert, update, delete on public.beneficiaries to authenticated;

-- El pedido guarda el carné de quien recoge, para identificarlo en la entrega.
alter table public.orders
    add column if not exists recipient_id_card text
        check (recipient_id_card is null or recipient_id_card ~ '^[0-9]{11}$');

-- create_order() se redefine entera (Postgres no permite parchear el cuerpo) solo
-- para guardar recipient_id_card; el resto es idéntico a la migración 20260907121000.
create or replace function public.create_order(payload jsonb)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_order_id    uuid;
    v_business_id uuid;
    v_total       numeric(10,2);
    v_lines       jsonb;
    v_business_count integer;
    v_bad_quantity   boolean;
    v_out_of_stock   text;
    v_cart_token     uuid;
    v_id_card        text;
begin
    if payload is null or jsonb_typeof(payload -> 'items') <> 'array'
       or jsonb_array_length(payload -> 'items') = 0 then
        raise exception 'El pedido no tiene productos.' using errcode = '22023';
    end if;

    -- Si el carrito traía reserva, sus propias unidades no le hacen de tope.
    v_cart_token := nullif(payload ->> 'cartToken', '')::uuid;

    v_id_card := nullif(regexp_replace(coalesce(payload ->> 'recipientIdCard', ''), '\s', '', 'g'), '');
    if v_id_card is not null and v_id_card !~ '^[0-9]{11}$' then
        raise exception 'El carné de identidad debe tener 11 dígitos.' using errcode = '22023';
    end if;

    -- Líneas repetidas del mismo producto se suman en una sola, y el precio y el
    -- nombre se resuelven contra la tabla: nunca se confía en lo que manda el cliente.
    with requested as (
        select (item ->> 'productId')::uuid as product_id,
               sum((item ->> 'quantity')::integer) as quantity
        from jsonb_array_elements(payload -> 'items') as item
        group by 1
    )
    select jsonb_agg(jsonb_build_object(
               'product_id', r.product_id,
               'quantity', r.quantity,
               'business_id', p.business_id,
               'product_name', p.name,
               'unit_price', p.price_usd
           ))
    into v_lines
    from requested r
    join public.products p on p.id = r.product_id
    join public.businesses b on b.id = p.business_id
    where p.available and b.active;

    if v_lines is null or jsonb_array_length(v_lines) <> (
        select count(distinct (item ->> 'productId')::uuid)
        from jsonb_array_elements(payload -> 'items') as item
    ) then
        raise exception 'Uno o más productos no existen o ya no están disponibles.'
            using errcode = '22023';
    end if;

    select sum((l ->> 'quantity')::integer * (l ->> 'unit_price')::numeric),
           min(l ->> 'business_id')::uuid,
           count(distinct l ->> 'business_id'),
           bool_or((l ->> 'quantity')::integer not between 1 and 100)
    into v_total, v_business_id, v_business_count, v_bad_quantity
    from jsonb_array_elements(v_lines) as l;

    if v_bad_quantity then
        raise exception 'Cantidad inválida: debe estar entre 1 y 100.' using errcode = '22023';
    end if;

    -- Cada negocio se paga por separado, así que un pedido no puede mezclar negocios.
    if v_business_count > 1 then
        raise exception 'Un pedido solo puede contener productos de un mismo negocio.'
            using errcode = '22023';
    end if;

    -- Se bloquean las filas antes de comprobar el stock: sin el lock, dos pedidos
    -- simultáneos podrían pasar los dos la comprobación y dejar el stock negativo.
    -- El orden por id evita que dos pedidos con productos comunes se bloqueen entre sí.
    perform 1
      from public.products
     where id in (select (l ->> 'product_id')::uuid from jsonb_array_elements(v_lines) as l)
     order by id
       for update;

    delete from public.stock_reservations where expires_at <= now();

    select string_agg(p.name, ', ' order by p.name)
      into v_out_of_stock
      from jsonb_array_elements(v_lines) as l
      join public.products p on p.id = (l ->> 'product_id')::uuid
     where public.available_stock(p.id, v_cart_token) < (l ->> 'quantity')::integer;

    if v_out_of_stock is not null then
        raise exception 'No hay stock suficiente de: %.', v_out_of_stock
            using errcode = '22023';
    end if;

    insert into public.orders (
        buyer_name, buyer_email, buyer_phone,
        recipient_name, recipient_phone, recipient_id_card, recipient_province,
        recipient_municipality, recipient_address,
        business_id, status, total_usd, notes, user_id
    )
    values (
        trim(payload ->> 'buyerName'),
        lower(trim(payload ->> 'buyerEmail')),
        trim(payload ->> 'buyerPhone'),
        trim(payload ->> 'recipientName'),
        trim(payload ->> 'recipientPhone'),
        v_id_card,
        payload ->> 'recipientProvince',
        trim(payload ->> 'recipientMunicipality'),
        trim(payload ->> 'recipientAddress'),
        v_business_id,
        'PendingPayment',
        v_total,
        nullif(trim(coalesce(payload ->> 'notes', '')), ''),
        -- Null si el comprador compró sin cuenta: el pedido sigue siendo anónimo
        -- y solo se consulta con su id.
        auth.uid()
    )
    returning id into v_order_id;

    insert into public.order_items (order_id, product_id, product_name, quantity, unit_price)
    select v_order_id,
           (l ->> 'product_id')::uuid,
           l ->> 'product_name',
           (l ->> 'quantity')::integer,
           (l ->> 'unit_price')::numeric
    from jsonb_array_elements(v_lines) as l;

    update public.products p
       set stock = p.stock - line.quantity
      from (
        select (l ->> 'product_id')::uuid as product_id,
               (l ->> 'quantity')::integer as quantity
        from jsonb_array_elements(v_lines) as l
      ) line
     where p.id = line.product_id;

    -- La reserva ya está cobrada en el stock: el carrito deja de necesitarla.
    if v_cart_token is not null then
        delete from public.stock_reservations where cart_token = v_cart_token;
    end if;

    return v_order_id;
end;
$$;

grant execute on function public.create_order(jsonb) to anon, authenticated;

-- get_order pasa a devolver también el carné del destinatario.
create or replace function public.get_order(p_order_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select jsonb_build_object(
        'id', o.id,
        'buyerName', o.buyer_name,
        'buyerEmail', o.buyer_email,
        'buyerPhone', o.buyer_phone,
        'recipientName', o.recipient_name,
        'recipientPhone', o.recipient_phone,
        'recipientIdCard', o.recipient_id_card,
        'recipientProvince', o.recipient_province,
        'recipientProvinceName', coalesce(pr.name, o.recipient_province),
        'recipientMunicipality', o.recipient_municipality,
        'recipientAddress', o.recipient_address,
        'businessId', o.business_id,
        'businessName', b.name,
        'status', o.status,
        'totalUsd', o.total_usd,
        'notes', o.notes,
        'createdAt', o.created_at,
        'items', coalesce((
            select jsonb_agg(jsonb_build_object(
                'id', i.id,
                'productId', i.product_id,
                'productName', i.product_name,
                'quantity', i.quantity,
                'unitPrice', i.unit_price
            ) order by i.product_name)
            from public.order_items i where i.order_id = o.id
        ), '[]'::jsonb)
    )
    from public.orders o
    join public.businesses b on b.id = o.business_id
    left join public.provinces pr on pr.code = o.recipient_province
    where o.id = p_order_id;
$$;

revoke all on function public.get_order(uuid) from public;
grant execute on function public.get_order(uuid) to anon, authenticated;
