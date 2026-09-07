import { useCallback, useEffect, useState } from 'react';
import { Navigate } from 'react-router-dom';
import { api } from '../api/client';
import type { Beneficiary, BeneficiaryInput, Municipality, Province, ProvinceRef } from '../api/types';
import { useAuth } from '../auth/AuthContext';
import { CheckIcon, CloseIcon, PencilIcon, PlusIcon, TrashIcon, UsersIcon } from '../components/Icon';
import { Modal } from '../components/Modal';

const emptyForm: BeneficiaryInput = {
  fullName: '',
  idCard: '',
  phone: '',
  municipalityId: '',
  address: '',
};

/** Libreta de personas que recogen los pedidos en Cuba. */
export function BeneficiariesPage() {
  const { user, loading: authLoading } = useAuth();
  const [beneficiaries, setBeneficiaries] = useState<Beneficiary[]>([]);
  const [provinces, setProvinces] = useState<ProvinceRef[]>([]);
  const [municipalities, setMunicipalities] = useState<Municipality[]>([]);
  const [province, setProvince] = useState<Province>('');
  const [form, setForm] = useState<BeneficiaryInput>(emptyForm);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [formOpen, setFormOpen] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setBeneficiaries(await api.listBeneficiaries());
      setError(null);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (!user) return;
    void load();
  }, [load, user]);

  useEffect(() => {
    api
      .listProvinces()
      .then(setProvinces)
      .catch((e: Error) => setError(e.message));
  }, []);

  useEffect(() => {
    if (!province) {
      setMunicipalities([]);
      return;
    }

    let cancelled = false;
    api
      .listMunicipalities(province)
      .then((data) => {
        if (cancelled) return;
        setMunicipalities(data);
        // El municipio elegido puede no existir en la provincia recién seleccionada.
        setForm((current) =>
          data.some((m) => m.id === current.municipalityId)
            ? current
            : { ...current, municipalityId: data[0]?.id ?? '' },
        );
      })
      .catch((e: Error) => {
        if (!cancelled) setError(e.message);
      });

    return () => {
      cancelled = true;
    };
  }, [province]);

  if (authLoading) return <p className="empty">Cargando…</p>;
  if (!user) return <Navigate to="/entrar" replace state={{ from: '/beneficiarios' }} />;

  const set = <K extends keyof BeneficiaryInput>(key: K, value: BeneficiaryInput[K]) =>
    setForm((current) => ({ ...current, [key]: value }));

  const closeForm = () => {
    setForm(emptyForm);
    setEditingId(null);
    setFormOpen(false);
  };

  const openCreate = () => {
    setForm(emptyForm);
    setEditingId(null);
    setProvince(provinces[0]?.code ?? '');
    setFormOpen(true);
  };

  const edit = (beneficiary: Beneficiary) => {
    setEditingId(beneficiary.id);
    setProvince(beneficiary.province);
    setForm({
      fullName: beneficiary.fullName,
      idCard: beneficiary.idCard,
      phone: beneficiary.phone,
      municipalityId: beneficiary.municipalityId,
      address: beneficiary.address,
    });
    setFormOpen(true);
  };

  const submit = async (event: React.FormEvent) => {
    event.preventDefault();
    try {
      await api.saveBeneficiary(form, editingId ?? undefined);
      setError(null);
      closeForm();
      await load();
    } catch (e) {
      setError((e as Error).message);
    }
  };

  const remove = async (beneficiary: Beneficiary) => {
    if (!confirm(`¿Eliminar a "${beneficiary.fullName}"? Tus pedidos anteriores no cambian.`)) return;
    try {
      await api.deleteBeneficiary(beneficiary.id);
      if (editingId === beneficiary.id) closeForm();
      await load();
    } catch (e) {
      setError((e as Error).message);
    }
  };

  return (
    <>
      <h1 className="page-title">Mis beneficiarios</h1>
      <p className="page-subtitle">
        Las personas que recogen tus pedidos en Cuba. Al confirmar un pedido puedes elegir una y sus
        datos se rellenan solos.
      </p>

      {error && (
        <div className="alert error" role="alert">
          {error}
        </div>
      )}

      <div className="page-toolbar">
        <h3 className="form-title">
          <UsersIcon size={18} /> Beneficiarios
        </h3>
        <button type="button" onClick={openCreate}>
          <PlusIcon /> Nuevo beneficiario
        </button>
      </div>

      {loading && <p className="empty">Cargando beneficiarios…</p>}
      {!loading && beneficiaries.length === 0 && (
        <p className="empty">Aún no has guardado ningún beneficiario.</p>
      )}

      {beneficiaries.length > 0 && (
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Nombre y apellidos</th>
                <th>Carné de identidad</th>
                <th>Teléfono</th>
                <th>Dirección</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {beneficiaries.map((beneficiary) => (
                <tr key={beneficiary.id}>
                  <td>{beneficiary.fullName}</td>
                  <td>{beneficiary.idCard}</td>
                  <td>{beneficiary.phone}</td>
                  <td>
                    {beneficiary.provinceName}, {beneficiary.municipality}
                    <br />
                    <span className="meta">{beneficiary.address}</span>
                  </td>
                  <td>
                    <span className="row-actions">
                      <button
                        type="button"
                        className="icon-button"
                        title="Editar beneficiario"
                        aria-label={`Editar ${beneficiary.fullName}`}
                        onClick={() => edit(beneficiary)}
                      >
                        <PencilIcon size={15} />
                      </button>
                      <button
                        type="button"
                        className="icon-button danger"
                        title="Eliminar beneficiario"
                        aria-label={`Eliminar ${beneficiary.fullName}`}
                        onClick={() => void remove(beneficiary)}
                      >
                        <TrashIcon size={15} />
                      </button>
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {formOpen && (
        <Modal
          title={
            <>
              {editingId ? <PencilIcon size={18} /> : <PlusIcon size={18} />}
              {editingId ? 'Editar beneficiario' : 'Nuevo beneficiario'}
            </>
          }
          onClose={closeForm}
        >
          <form onSubmit={submit}>
            <div className="field">
              <label htmlFor="beneficiaryName">Nombre y apellidos</label>
              <input
                id="beneficiaryName"
                required
                maxLength={160}
                value={form.fullName}
                onChange={(e) => set('fullName', e.target.value)}
              />
            </div>
            <div className="field-row">
              <div className="field">
                <label htmlFor="beneficiaryIdCard">Carné de identidad</label>
                <input
                  id="beneficiaryIdCard"
                  required
                  inputMode="numeric"
                  pattern="[0-9]{11}"
                  title="11 dígitos"
                  value={form.idCard}
                  onChange={(e) => set('idCard', e.target.value.replace(/\D/g, '').slice(0, 11))}
                />
                <p className="field-hint">11 dígitos, sin espacios ni guiones.</p>
              </div>
              <div className="field">
                <label htmlFor="beneficiaryPhone">Teléfono en Cuba</label>
                <input
                  id="beneficiaryPhone"
                  required
                  maxLength={40}
                  value={form.phone}
                  onChange={(e) => set('phone', e.target.value)}
                />
              </div>
            </div>
            <div className="field-row">
              <div className="field">
                <label htmlFor="beneficiaryProvince">Provincia</label>
                <select
                  id="beneficiaryProvince"
                  value={province}
                  onChange={(e) => setProvince(e.target.value)}
                >
                  {provinces.map((p) => (
                    <option key={p.code} value={p.code}>
                      {p.name}
                    </option>
                  ))}
                </select>
              </div>
              <div className="field">
                <label htmlFor="beneficiaryMunicipality">Municipio</label>
                <select
                  id="beneficiaryMunicipality"
                  required
                  value={form.municipalityId}
                  onChange={(e) => set('municipalityId', e.target.value)}
                >
                  {municipalities.map((m) => (
                    <option key={m.id} value={m.id}>
                      {m.name}
                    </option>
                  ))}
                </select>
              </div>
            </div>
            <div className="field">
              <label htmlFor="beneficiaryAddress">Dirección</label>
              <textarea
                id="beneficiaryAddress"
                required
                rows={3}
                maxLength={500}
                value={form.address}
                onChange={(e) => set('address', e.target.value)}
              />
              <p className="field-hint">
                Incluye calle, número, entre calles y una referencia para encontrar la casa.
              </p>
            </div>
            <div className="modal-footer">
              <button type="button" className="secondary" onClick={closeForm}>
                <CloseIcon /> Cancelar
              </button>
              <button type="submit">
                {editingId ? <CheckIcon /> : <PlusIcon />}
                {editingId ? 'Guardar cambios' : 'Crear beneficiario'}
              </button>
            </div>
          </form>
        </Modal>
      )}
    </>
  );
}
