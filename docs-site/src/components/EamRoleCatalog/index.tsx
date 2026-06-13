import React, { useEffect, useMemo, useState } from 'react';
import { useHistory, useLocation } from '@docusaurus/router';
import catalog from '../../data/eam-role-catalog.json';
import styles from './styles.module.css';

type Authority = 'authoritative' | 'curated' | 'heuristic' | 'derived';

interface RecommendedConfig {
  pimRequired: boolean;
  maxActivation: string;
  maxActivationLabel: string;
  requireMfa: boolean;
  requireApproval: boolean;
  requireJustification: boolean;
  authContext: string;
  severity: 'High' | 'Medium' | 'Low';
}

interface Role {
  displayName: string;
  templateId: string;
  description: string;
  isPrivileged: boolean;
  eamPlane: 'Control' | 'Management' | 'Data';
  securityLevel: 'Privileged' | 'Specialized' | 'Enterprise';
  levelBasis: 'isPrivileged' | 'escape-clause' | 'plane-mapping';
  reviewNeeded: boolean;
  recommendedConfig: RecommendedConfig;
  sourceAuthority: {
    isPrivileged: Authority;
    eamPlane: Authority;
    securityLevel: Authority;
    recommendedConfig: Authority;
  };
  note: string | null;
}

const ROLES = (catalog as { roles: Role[] }).roles;

const PLANES = ['Control', 'Management', 'Data'] as const;
const LEVELS = ['Privileged', 'Specialized', 'Enterprise'] as const;
const BASES = ['isPrivileged', 'escape-clause', 'plane-mapping'] as const;

type Plane = typeof PLANES[number];
type Level = typeof LEVELS[number];
type Basis = typeof BASES[number];

// Severity tokens drive colour: High = red, Med = amber, Low = green, Zinc = neutral.
const PLANE_TOK: Record<Plane, string> = { Control: 'High', Management: 'Med', Data: 'Low' };
// Level rail/tint colours: Privileged red, Specialized amber, Enterprise neutral.
const LEVEL_TOK: Record<Level, string> = { Privileged: 'High', Specialized: 'Med', Enterprise: 'Zinc' };
// Strictness order for sorting (Privileged is strictest).
const LEVEL_ORDER: Record<Level, number> = { Privileged: 0, Specialized: 1, Enterprise: 2 };
// Blast-radius order for sorting (Control is widest), matching the matrix rows.
const PLANE_ORDER: Record<Plane, number> = { Control: 0, Management: 1, Data: 2 };

const BASIS_LABEL: Record<Basis, string> = {
  isPrivileged: 'isPrivileged',
  'escape-clause': 'escape clause',
  'plane-mapping': 'plane mapping',
};

// Plain-language trust labels. The raw Graph/generator terms (authoritative, curated,
// derived, heuristic) are jargon, so the UI shows everyday words instead.
const AUTHORITY_LABEL: Record<Authority, string> = {
  authoritative: 'from Microsoft',
  curated: 'reviewed',
  derived: 'by rule',
  heuristic: 'unreviewed',
};

// Per-role "why this level": the deciding rule plus a source to verify it.
const WHY_LEVEL: Record<Basis, { rule: string; href: string; source: string }> = {
  isPrivileged: {
    rule: 'Rule 1: Microsoft marks this role isPrivileged.',
    href: 'https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/privileged-roles-permissions',
    source: 'Privileged roles and permissions',
  },
  'escape-clause': {
    rule: 'Rule 2: blast-radius escape clause. The role owns a full M365 workload.',
    href: 'https://learn.microsoft.com/en-us/security/privileged-access-workstations/privileged-access-security-levels',
    source: 'Securing privileged access security levels',
  },
  'plane-mapping': {
    rule: 'Rule 3: EAM plane mapping.',
    href: 'https://learn.microsoft.com/en-us/security/privileged-access-workstations/privileged-access-access-model',
    source: 'Enterprise Access Model',
  },
};

function bool(v: boolean): string {
  return v ? 'Yes' : 'No';
}

function activationHours(pt: string): number {
  const m = /^PT(\d+)H$/.exec(pt);
  return m ? Number(m[1]) : Number.MAX_SAFE_INTEGER;
}

// Canonical expectedConfig per security level (docs/eam-pim-classification.md, Part 2.5).
// authContext is a tenant-specific slug placeholder; Enterprise enforces neither an auth
// context nor allowPermanentEligible. Severity is derived by the scanner from securityLevel,
// so the emitted file carries securityLevel, not a literal severity field.
const EXPECTED_BY_LEVEL: Record<Level, Record<string, unknown>> = {
  Privileged: {
    maxActivationDuration: 'PT1H',
    requireJustification: true,
    requireMFA: true,
    authContext: 'phish-resistant-sif',
    requireApproval: true,
    allowPermanentEligible: false,
    allowPermanentActive: false,
  },
  Specialized: {
    maxActivationDuration: 'PT4H',
    requireJustification: true,
    requireMFA: true,
    authContext: 'phish-resistant-no-sif',
    requireApproval: true,
    allowPermanentEligible: false,
    allowPermanentActive: false,
  },
  Enterprise: {
    maxActivationDuration: 'PT8H',
    requireJustification: true,
    requireMFA: true,
    requireApproval: false,
    allowPermanentActive: false,
  },
};

// Build a ready-to-use AccessModel/*.json file for every role at a security level.
// A per-level file spans planes, so it carries securityLevel but no single plane.
function buildAccessModelJson(level: Level): string {
  const roles = ROLES.filter((r) => r.securityLevel === level);
  const payload = {
    name: `EAM ${level} Roles`,
    description: `Microsoft Entra directory roles classified ${level} under the Enterprise Access Model. Generated from the PIM Monitor EAM Role Catalog.`,
    securityLevel: level,
    roles: roles.map((r) => ({ id: r.templateId, displayName: r.displayName })),
    expectedConfig: EXPECTED_BY_LEVEL[level],
  };
  return JSON.stringify(payload, null, 2);
}

// Build a single-role AccessModel entry (Tier 3.1 per-role remediation).
// A single role has one plane, so it carries both plane and securityLevel.
function buildRoleJson(r: Role): string {
  const payload = {
    name: `EAM ${r.securityLevel} Roles`,
    description: `${r.displayName} classified ${r.securityLevel} under the Enterprise Access Model. Generated from the PIM Monitor EAM Role Catalog.`,
    plane: r.eamPlane,
    securityLevel: r.securityLevel,
    roles: [{ id: r.templateId, displayName: r.displayName }],
    expectedConfig: EXPECTED_BY_LEVEL[r.securityLevel],
  };
  return JSON.stringify(payload, null, 2);
}

function AuthorityToken({ authority }: { authority: Authority }) {
  return (
    <span className={`${styles.tok} ${styles[`tok_${authority}`]}`} title={`Where this value comes from: ${AUTHORITY_LABEL[authority]}`}>
      {AUTHORITY_LABEL[authority]}
    </span>
  );
}

function WarnIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
      <path d="m21.73 18-8-14a2 2 0 0 0-3.46 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z" />
      <path d="M12 9v4M12 17h.01" />
    </svg>
  );
}

type SortKey = 'name' | 'plane' | 'level' | 'priv' | 'activation';

interface FacetState {
  query: string;
  plane: string;
  level: string;
  basis: string;
  privOnly: boolean;
  reviewOnly: boolean;
}

const DEFAULT_FACETS: FacetState = {
  query: '',
  plane: 'All',
  level: 'All',
  basis: 'All',
  privOnly: false,
  reviewOnly: false,
};

function parseFacets(search: string): FacetState {
  const p = new URLSearchParams(search);
  return {
    query: p.get('q') ?? '',
    plane: p.get('plane') ?? 'All',
    level: p.get('level') ?? 'All',
    basis: p.get('basis') ?? 'All',
    privOnly: p.get('priv') === '1',
    reviewOnly: p.get('review') === '1',
  };
}

function facetsToSearch(f: FacetState): string {
  const p = new URLSearchParams();
  if (f.query) p.set('q', f.query);
  if (f.plane !== 'All') p.set('plane', f.plane);
  if (f.level !== 'All') p.set('level', f.level);
  if (f.basis !== 'All') p.set('basis', f.basis);
  if (f.privOnly) p.set('priv', '1');
  if (f.reviewOnly) p.set('review', '1');
  const s = p.toString();
  return s ? `?${s}` : '';
}

export default function EamRoleCatalog(): JSX.Element {
  const history = useHistory();
  const location = useLocation();

  const [facets, setFacets] = useState<FacetState>(DEFAULT_FACETS);
  const [sortKey, setSortKey] = useState<SortKey>('name');
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('asc');
  const [expanded, setExpanded] = useState<string | null>(null);
  const [copied, setCopied] = useState<string | null>(null);
  const [copiedRole, setCopiedRole] = useState<string | null>(null);

  // Hydrate facets from the URL once on mount (SSR renders defaults, avoiding a mismatch).
  useEffect(() => {
    setFacets(parseFacets(location.search));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Mirror facet state back into the URL so a filtered view is shareable.
  useEffect(() => {
    const next = facetsToSearch(facets);
    if (next !== location.search) {
      history.replace({ search: next });
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [facets]);

  function patch(p: Partial<FacetState>) {
    setFacets((f) => ({ ...f, ...p }));
  }

  // Toggle a single-axis facet: clicking the active value clears it.
  function toggleFacet(key: 'plane' | 'level' | 'basis', value: string) {
    setFacets((f) => ({ ...f, [key]: f[key] === value ? 'All' : value }));
  }

  // Matrix cell click sets both axes at once.
  function selectCell(plane: Plane, level: Level) {
    setFacets((f) => {
      const active = f.plane === plane && f.level === level;
      return { ...f, plane: active ? 'All' : plane, level: active ? 'All' : level };
    });
  }

  function setSort(key: SortKey) {
    if (key === sortKey) {
      setSortDir((d) => (d === 'asc' ? 'desc' : 'asc'));
    } else {
      setSortKey(key);
      setSortDir('asc');
    }
  }

  const filtered = useMemo(() => {
    const q = facets.query.trim().toLowerCase();
    const rows = ROLES.filter((r) => {
      if (facets.plane !== 'All' && r.eamPlane !== facets.plane) return false;
      if (facets.level !== 'All' && r.securityLevel !== facets.level) return false;
      if (facets.basis !== 'All' && r.levelBasis !== facets.basis) return false;
      if (facets.privOnly && !r.isPrivileged) return false;
      if (facets.reviewOnly && !r.reviewNeeded) return false;
      if (q && !(r.displayName.toLowerCase().includes(q) || r.description.toLowerCase().includes(q))) {
        return false;
      }
      return true;
    });
    const dir = sortDir === 'asc' ? 1 : -1;
    rows.sort((a, b) => {
      let c = 0;
      if (sortKey === 'name') c = a.displayName.localeCompare(b.displayName);
      else if (sortKey === 'plane') c = PLANE_ORDER[a.eamPlane] - PLANE_ORDER[b.eamPlane];
      else if (sortKey === 'level') c = LEVEL_ORDER[a.securityLevel] - LEVEL_ORDER[b.securityLevel];
      else if (sortKey === 'priv') c = (a.isPrivileged === b.isPrivileged ? 0 : a.isPrivileged ? -1 : 1);
      else c = activationHours(a.recommendedConfig.maxActivation) - activationHours(b.recommendedConfig.maxActivation);
      if (c === 0) c = a.displayName.localeCompare(b.displayName);
      return c * dir;
    });
    return rows;
  }, [facets, sortKey, sortDir]);

  // 3x3 plane x level matrix counts and per-axis totals.
  const matrix = useMemo(() => {
    const cell: Record<string, number> = {};
    PLANES.forEach((p) => LEVELS.forEach((l) => (cell[`${p}|${l}`] = 0)));
    ROLES.forEach((r) => (cell[`${r.eamPlane}|${r.securityLevel}`] += 1));
    const rowTotal = (p: Plane) => LEVELS.reduce((s, l) => s + cell[`${p}|${l}`], 0);
    const colTotal = (l: Level) => PLANES.reduce((s, p) => s + cell[`${p}|${l}`], 0);
    return { cell, rowTotal, colTotal };
  }, []);

  // Confidence gauge: four honest indicators of how far the catalog can be trusted.
  const trust = useMemo(() => ({
    authoritative: ROLES.filter((r) => r.isPrivileged).length,
    curated: ROLES.filter((r) => r.sourceAuthority.eamPlane === 'curated').length,
    heuristic: ROLES.filter((r) => r.sourceAuthority.eamPlane === 'heuristic').length,
    review: ROLES.filter((r) => r.reviewNeeded).length,
  }), []);

  const planeCount = (p: Plane) => ROLES.filter((r) => r.eamPlane === p).length;
  const levelCount = (l: Level) => ROLES.filter((r) => r.securityLevel === l).length;
  const basisCount = (b: Basis) => ROLES.filter((r) => r.levelBasis === b).length;

  async function copyText(text: string, mark: () => void) {
    try {
      await navigator.clipboard.writeText(text);
      mark();
    } catch {
      // Clipboard unavailable (e.g. insecure context): no-op.
    }
  }

  function copyAccessModel(lvl: Level) {
    copyText(buildAccessModelJson(lvl), () => {
      setCopied(lvl);
      setTimeout(() => setCopied((c) => (c === lvl ? null : c)), 2000);
    });
  }

  function copyRole(r: Role) {
    copyText(buildRoleJson(r), () => {
      setCopiedRole(r.templateId);
      setTimeout(() => setCopiedRole((c) => (c === r.templateId ? null : c)), 2000);
    });
  }

  const sortMark = (key: SortKey) => (sortKey === key ? (sortDir === 'asc' ? '↑' : '↓') : '⇅');

  function SortTh({ k, children }: { k: SortKey; children: React.ReactNode }) {
    return (
      <th className={styles.sortable} onClick={() => setSort(k)} title="Click to sort">
        {children}
        <span className={`${styles.sortMark} ${sortKey === k ? styles.sortMarkOn : ''}`}>{sortMark(k)}</span>
      </th>
    );
  }

  return (
    <div className={styles.catalog}>
      {/* Confidence gauge (Tier 1.4) */}
      <div className={styles.sectionLbl}>classification confidence</div>
      <div className={styles.gaugeGrid}>
        <div className={styles.gauge}>
          <div className={`${styles.gaugeLabel} ${styles.lblLow}`}>from Microsoft</div>
          <div className={styles.gaugeValue}>{trust.authoritative}</div>
          <div className={styles.gaugeSub}>isPrivileged flag</div>
        </div>
        <div className={styles.gauge}>
          <div className={styles.gaugeLabel}>reviewed</div>
          <div className={styles.gaugeValue}>{trust.curated}</div>
          <div className={styles.gaugeSub}>by hand</div>
        </div>
        <div className={styles.gauge}>
          <div className={`${styles.gaugeLabel} ${styles.lblMed}`}>unreviewed</div>
          <div className={styles.gaugeValue}>{trust.heuristic}</div>
          <div className={styles.gaugeSub}>keyword guess</div>
        </div>
        <div className={`${styles.gauge} ${styles.gaugeNow}`}>
          <div className={styles.gaugeLabel}>need review</div>
          <div className={styles.gaugeValue}>{trust.review}</div>
          <div className={styles.gaugeSub}>flagged for you</div>
        </div>
      </div>

      {/* Plane x Level matrix (Tier 1.1) replaces the two stat grids */}
      <div className={styles.sectionLbl}>plane × level</div>
      <p className={styles.matrixHint}>
        Rows are <strong>planes</strong> (blast radius), columns are <strong>levels</strong> (strictness).
        Click a cell to filter both, or a header to filter one.
      </p>
      <div className={styles.matrixWrap}>
        <table className={styles.matrix}>
          <thead>
            <tr>
              <th className={styles.matrixCorner}>
                <span className={styles.axisLevel}>level →</span>
                <span className={styles.axisPlane}>plane ↓</span>
              </th>
              {LEVELS.map((l) => (
                <th
                  key={l}
                  className={`${styles.matrixColHd} ${facets.level === l ? styles.matrixAxisOn : ''}`}
                  onClick={() => toggleFacet('level', l)}
                >
                  {l}
                </th>
              ))}
              <th className={styles.matrixTotalHd}>Σ</th>
            </tr>
          </thead>
          <tbody>
            {PLANES.map((p) => (
              <tr key={p}>
                <th
                  className={`${styles.matrixRowHd} ${facets.plane === p ? styles.matrixAxisOn : ''}`}
                  onClick={() => toggleFacet('plane', p)}
                >
                  {p}
                </th>
                {LEVELS.map((l) => {
                  const n = matrix.cell[`${p}|${l}`];
                  const on = facets.plane === p && facets.level === l;
                  return (
                    <td
                      key={l}
                      className={`${styles.matrixCell} ${styles[`cell${LEVEL_TOK[l]}`]} ${on ? styles.matrixCellOn : ''} ${n === 0 ? styles.matrixZero : ''}`}
                      onClick={() => selectCell(p, l)}
                    >
                      {n}
                    </td>
                  );
                })}
                <td className={styles.matrixTotal}>{matrix.rowTotal(p)}</td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr>
              <th className={styles.matrixTotalHd}>Σ</th>
              {LEVELS.map((l) => (
                <td key={l} className={styles.matrixTotal}>{matrix.colTotal(l)}</td>
              ))}
              <td className={styles.matrixGrand}>{ROLES.length}</td>
            </tr>
          </tfoot>
        </table>
      </div>

      {/* Search */}
      <div className={styles.sectionLbl}>filter</div>
      <div className={styles.controls}>
        <input
          className={styles.search}
          type="search"
          placeholder="search role name or description..."
          value={facets.query}
          onChange={(e) => patch({ query: e.target.value })}
          aria-label="Search roles"
        />
      </div>

      {/* Facet chips (Tier 2.1) */}
      <div className={styles.chipRow}>
        <span className={styles.chipGroupLbl}>plane</span>
        {PLANES.map((p) => (
          <button
            key={p}
            type="button"
            className={`${styles.chip} ${facets.plane === p ? styles.chipOn : ''}`}
            onClick={() => toggleFacet('plane', p)}
          >
            {p} <span className={styles.chipCount}>{planeCount(p)}</span>
          </button>
        ))}
      </div>
      <div className={styles.chipRow}>
        <span className={styles.chipGroupLbl}>level</span>
        {LEVELS.map((l) => (
          <button
            key={l}
            type="button"
            className={`${styles.chip} ${facets.level === l ? styles.chipOn : ''}`}
            onClick={() => toggleFacet('level', l)}
          >
            {l} <span className={styles.chipCount}>{levelCount(l)}</span>
          </button>
        ))}
      </div>
      <div className={styles.chipRow}>
        <span className={styles.chipGroupLbl}>level basis</span>
        {BASES.map((b) => (
          <button
            key={b}
            type="button"
            className={`${styles.chip} ${facets.basis === b ? styles.chipOn : ''}`}
            onClick={() => toggleFacet('basis', b)}
          >
            {BASIS_LABEL[b]} <span className={styles.chipCount}>{basisCount(b)}</span>
          </button>
        ))}
        <label className={styles.toggle}>
          <input type="checkbox" checked={facets.privOnly} onChange={(e) => patch({ privOnly: e.target.checked })} />
          isPrivileged only
        </label>
        <label className={styles.toggle}>
          <input type="checkbox" checked={facets.reviewOnly} onChange={(e) => patch({ reviewOnly: e.target.checked })} />
          review needed
        </label>
        <button type="button" className={styles.clearBtn} onClick={() => patch(DEFAULT_FACETS)}>
          clear
        </button>
      </div>

      {/* Export bridge: per-level files */}
      <div className={styles.export}>
        <span className={styles.exportLabel}>copy accessmodel json</span>
        {LEVELS.map((l) => (
          <button
            key={l}
            type="button"
            className={`${styles.btn} ${copied === l ? styles.btnPrimary : styles.btnSecondary}`}
            onClick={() => copyAccessModel(l)}
          >
            {copied === l ? 'copied' : `${l} file`}
          </button>
        ))}
      </div>

      <p className={styles.resultCount}>{filtered.length} / {ROLES.length} roles</p>

      {/* Table */}
      <div className={styles.tableWrap}>
        <table className={styles.table}>
          <thead>
            <tr>
              <SortTh k="name">Role</SortTh>
              <SortTh k="plane">Plane</SortTh>
              <SortTh k="level">Level</SortTh>
              <SortTh k="priv">isPriv</SortTh>
              <SortTh k="activation">Max activation</SortTh>
              <th>Details</th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((r) => {
              const isOpen = expanded === r.templateId;
              const why = WHY_LEVEL[r.levelBasis];
              return (
                <React.Fragment key={r.templateId}>
                  <tr
                    className={`${styles.row} ${styles[`rail${LEVEL_TOK[r.securityLevel]}`]} ${isOpen ? styles.rowOpen : ''}`}
                    onClick={() => setExpanded(isOpen ? null : r.templateId)}
                  >
                    <td className={styles.roleCell}>
                      {r.displayName}
                      {r.reviewNeeded && <span className={styles.reviewTok}>review</span>}
                      {r.note && <span className={styles.noteDot} title="Has a classification note">note</span>}
                    </td>
                    <td>
                      <span
                        className={`${styles.badge} ${styles[`badge${PLANE_TOK[r.eamPlane]}`]} ${styles.badgeClickable}`}
                        title={`Filter by ${r.eamPlane} plane`}
                        onClick={(e) => { e.stopPropagation(); toggleFacet('plane', r.eamPlane); }}
                      >
                        {r.eamPlane}
                      </span>
                    </td>
                    <td>
                      <span
                        className={`${styles.badge} ${styles[`badge${LEVEL_TOK[r.securityLevel]}`]} ${styles.badgeClickable}`}
                        title={`Filter by ${r.securityLevel} level`}
                        onClick={(e) => { e.stopPropagation(); toggleFacet('level', r.securityLevel); }}
                      >
                        {r.securityLevel}
                      </span>
                    </td>
                    <td className={styles.center}>
                      {r.isPrivileged ? (
                        <span className={styles.privYes}>yes</span>
                      ) : r.levelBasis === 'escape-clause' ? (
                        <span className={styles.privEscape} title="Not flagged isPrivileged, but the blast-radius escape clause raises it to Privileged">no*</span>
                      ) : (
                        <span className={styles.privNo}>no</span>
                      )}
                    </td>
                    <td className={styles.mono}>{r.recommendedConfig.maxActivationLabel}</td>
                    <td className={styles.center}><span className={styles.expand}>{isOpen ? 'hide' : 'details'}</span></td>
                  </tr>
                  {isOpen && (
                    <tr className={styles.detailRow}>
                      <td colSpan={6}>
                        <div className={styles.detail}>
                          <p className={styles.desc}>{r.description}</p>

                          {/* Classification lineage (Tier 1.3): plane -> level -> policy */}
                          <div className={styles.lineage}>
                            <span className={styles.lineageHop}>
                              <span className={styles.lineageVal}>{r.eamPlane}</span>
                              <span className={styles.lineageSub}>plane <AuthorityToken authority={r.sourceAuthority.eamPlane} /></span>
                            </span>
                            <span className={styles.lineageArrow}>→</span>
                            <span className={styles.lineageHop}>
                              <span className={styles.lineageVal}>{r.securityLevel}</span>
                              <span className={styles.lineageSub}>level <AuthorityToken authority={r.sourceAuthority.securityLevel} /></span>
                            </span>
                            <span className={styles.lineageArrow}>→</span>
                            <span className={styles.lineageHop}>
                              <span className={styles.lineageVal}>{r.recommendedConfig.maxActivationLabel}</span>
                              <span className={styles.lineageSub}>recommended PIM policy</span>
                            </span>
                          </div>

                          {/* Why this level (Tier 3.2) */}
                          <div className={styles.why}>
                            <span className={styles.whyLbl}>why {r.securityLevel.toLowerCase()}</span>
                            <span className={styles.whyText}>
                              {r.levelBasis === 'plane-mapping' ? `${why.rule} (${r.eamPlane} → ${r.securityLevel}).` : why.rule}{' '}
                              <a href={why.href} target="_blank" rel="noreferrer">{why.source} ↗</a>
                            </span>
                          </div>

                          <div className={styles.detailGrid}>
                            <div className={styles.panel}>
                              <div className={styles.panelHd}>recommended pim activation policy</div>
                              <dl className={styles.dl}>
                                <div><dt>PIM required</dt><dd>{bool(r.recommendedConfig.pimRequired)}</dd></div>
                                <div><dt>Max activation</dt><dd>{r.recommendedConfig.maxActivationLabel} <code>{r.recommendedConfig.maxActivation}</code></dd></div>
                                <div><dt>MFA on activation</dt><dd>{bool(r.recommendedConfig.requireMfa)}</dd></div>
                                <div><dt>Approval required</dt><dd>{bool(r.recommendedConfig.requireApproval)}</dd></div>
                                <div><dt>Justification</dt><dd>{bool(r.recommendedConfig.requireJustification)}</dd></div>
                                <div><dt>Auth context</dt><dd>{r.recommendedConfig.authContext}</dd></div>
                              </dl>
                            </div>

                            <div className={styles.panel}>
                              <div className={styles.panelHd}>where this comes from</div>
                              <dl className={styles.dl}>
                                <div><dt>isPrivileged</dt><dd>{bool(r.isPrivileged)} <AuthorityToken authority={r.sourceAuthority.isPrivileged} /></dd></div>
                                <div><dt>EAM plane</dt><dd>{r.eamPlane} <AuthorityToken authority={r.sourceAuthority.eamPlane} /></dd></div>
                                <div><dt>Security level</dt><dd>{r.securityLevel} <AuthorityToken authority={r.sourceAuthority.securityLevel} /></dd></div>
                                <div><dt>Level basis</dt><dd>{BASIS_LABEL[r.levelBasis]}</dd></div>
                                <div><dt>PIM values</dt><dd>SPA guidance <AuthorityToken authority={r.sourceAuthority.recommendedConfig} /></dd></div>
                              </dl>
                            </div>
                          </div>

                          {r.note && (
                            <div className={styles.note}>
                              <span className={styles.noteIcon}><WarnIcon /></span>
                              <div>
                                <div className={styles.noteTitle}>Note</div>
                                <div className={styles.noteBody}>{r.note}</div>
                              </div>
                            </div>
                          )}

                          {/* Per-role remediation (Tier 3.1) */}
                          <div className={styles.remediation}>
                            <span className={styles.remediationLbl}>how to enforce</span>
                            <button
                              type="button"
                              className={`${styles.btn} ${copiedRole === r.templateId ? styles.btnPrimary : styles.btnSecondary}`}
                              onClick={(e) => { e.stopPropagation(); copyRole(r); }}
                            >
                              {copiedRole === r.templateId ? 'copied' : 'copy role json'}
                            </button>
                            <span className={styles.remediationHint}>single-role AccessModel entry</span>
                          </div>

                          <p className={styles.templateId}>template id <code>{r.templateId}</code></p>
                        </div>
                      </td>
                    </tr>
                  )}
                </React.Fragment>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
