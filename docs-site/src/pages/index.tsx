import Link from '@docusaurus/Link';
import Layout from '@theme/Layout';
import styles from './index.module.css';
import { APP_VERSION } from '../constants';

function NotificationCard() {
  return (
    <div className={styles.notif}>
      <div className={styles.notifHdr}>
        <span className={styles.notifBrand}>pim/monitor</span>
        <span className={styles.notifSub}>change report</span>
      </div>
      <div className={styles.notifBar}>
        <span className={styles.notifBarItem}>Total <strong>3</strong></span>
        <span className={`${styles.notifBarItem} ${styles.notifHigh}`}>High 1</span>
        <span className={`${styles.notifBarItem} ${styles.notifMed}`}>Medium 2</span>
        <span className={styles.notifBarItem}>Low 0</span>
        <span className={styles.notifTs}>2026-04-26T06:00Z</span>
      </div>
      <div className={styles.notifChanges}>
        <div className={`${styles.notifChange} ${styles.notifChangeHigh}`}>
          <span className={styles.notifChip}><span className={styles.notifChipBr}>[</span><span className={styles.notifChipGl}>!!</span><span className={styles.notifChipBr}>]</span> high</span>
          <span className={styles.notifChangeTitle}>Global Administrator</span>
          <span className={styles.notifChangeDesc}><span className={styles.sigAdd}>+</span> permanent assignment added</span>
        </div>
        <div className={`${styles.notifChange} ${styles.notifChangeMed}`}>
          <span className={styles.notifChip}><span className={styles.notifChipBr}>[</span><span className={styles.notifChipGlMed}>!</span><span className={styles.notifChipBr}>]</span> med</span>
          <span className={styles.notifChangeTitle}>Exchange Administrator</span>
          <span className={styles.notifChangeDesc}><span className={styles.sigMod}>M</span> activation duration 8h → 24h</span>
        </div>
        <div className={`${styles.notifChange} ${styles.notifChangeMed}`}>
          <span className={styles.notifChip}><span className={styles.notifChipBr}>[</span><span className={styles.notifChipGlMed}>!</span><span className={styles.notifChipBr}>]</span> med</span>
          <span className={styles.notifChangeTitle}>Exchange Administrator</span>
          <span className={styles.notifChangeDesc}><span className={styles.sigMod}>M</span> max eligible duration 180d → 365d</span>
        </div>
      </div>
      <div className={styles.notifFooter}>
        <span className={styles.notifViewDiff}>view diff →</span>
        <span className={styles.notifFooterLabel}>email · teams · slack · discord</span>
      </div>
    </div>
  );
}

function DiffPanel() {
  return (
    <div className={styles.diff}>
      <div className={styles.diffHdr}>
        <span className={styles.diffPath}>policy.json · global-administrator</span>
        <span className={styles.diffStats}>
          <span className={styles.diffDel}>−1</span>
          <span className={styles.diffAdd}>+2</span>
        </span>
      </div>
      <div className={styles.diffBody}>
        <div className={styles.diffSide}>
          <div className={styles.diffSideHdr}>
            <span>before</span><span className={styles.diffSha}>8e2f01b</span>
          </div>
          <div className={styles.diffHunk}>@@ Enablement_EndUser_Assignment</div>
          <div className={styles.ln}><span className={styles.lineNo}>42</span><span className={styles.code}>{'{'}</span></div>
          <div className={`${styles.ln} ${styles.lnDel}`}><span className={styles.lineNo}>43</span><span className={styles.code}>  "requireMfa": false,</span></div>
          <div className={`${styles.ln} ${styles.lnEmpty}`}><span className={styles.lineNo}></span><span className={styles.code}></span></div>
          <div className={`${styles.ln} ${styles.lnEmpty}`}><span className={styles.lineNo}></span><span className={styles.code}></span></div>
          <div className={styles.ln}><span className={styles.lineNo}>44</span><span className={styles.code}>  "enabledRules": ["Justification"]</span></div>
          <div className={styles.ln}><span className={styles.lineNo}>45</span><span className={styles.code}>{'}'}</span></div>
        </div>
        <div className={styles.diffSide}>
          <div className={styles.diffSideHdr}>
            <span>after</span><span className={styles.diffSha}>4f3c9a1</span>
          </div>
          <div className={styles.diffHunk}>@@ Enablement_EndUser_Assignment</div>
          <div className={styles.ln}><span className={styles.lineNo}>42</span><span className={styles.code}>{'{'}</span></div>
          <div className={`${styles.ln} ${styles.lnAdd}`}><span className={styles.lineNo}>43</span><span className={styles.code}>  "requireMfa": true,</span></div>
          <div className={`${styles.ln} ${styles.lnAdd}`}><span className={styles.lineNo}>44</span><span className={styles.code}>  "requireJustification": true,</span></div>
          <div className={styles.ln}><span className={styles.lineNo}>45</span><span className={styles.code}>  "enabledRules": ["Justification"]</span></div>
          <div className={styles.ln}><span className={styles.lineNo}>46</span><span className={styles.code}>{'}'}</span></div>
          <div className={`${styles.ln} ${styles.lnEmpty}`}><span className={styles.lineNo}></span><span className={styles.code}></span></div>
        </div>
      </div>
    </div>
  );
}

function GitLog() {
  return (
    <div className={styles.gitLog}>
      <div className={`${styles.commit} ${styles.commitNow}`}>
        <span className={styles.sha}>4f3c9a1</span>
        <span className={styles.msg}>scan: permanent grant on <code>Global Administrator</code></span>
        <span className={styles.time}>06:00</span>
      </div>
      <div className={`${styles.commit} ${styles.commitMed}`}>
        <span className={styles.sha}>a1bde02</span>
        <span className={styles.msg}>scan: policy duration 8h→24h on <code>Exchange Admin</code></span>
        <span className={styles.time}>00:00</span>
      </div>
      <div className={styles.commit}>
        <span className={styles.sha}>8e2f01b</span>
        <span className={`${styles.msg} ${styles.msgMuted}`}>scan: no changes</span>
        <span className={styles.time}>18:00</span>
      </div>
      <div className={styles.commit}>
        <span className={styles.sha}>77c0114</span>
        <span className={`${styles.msg} ${styles.msgMuted}`}>scan: no changes</span>
        <span className={styles.time}>12:00</span>
      </div>
    </div>
  );
}

export default function Home(): JSX.Element {
  return (
    <Layout title="PIM Monitor" description="Continuous monitoring of Microsoft Entra ID PIM state with git-based audit trail">
      <main className={styles.heroPage} data-theme="dark">
        <div className={styles.heroInner}>
          <div className={styles.heroLeft}>
            <div className={styles.heroText}>
              <p className={styles.heroEyebrow}>every change · a commit</p>
              <h1 className={styles.heroTitle}>
                Your audit trail<br />
                is <span className={styles.heroAccent}>git history</span>.
              </h1>
              <p className={styles.heroSub}>
                An Azure DevOps pipeline that scans Entra ID PIM 4 times a day
                by default and commits every change. No dashboard. No UI. Just commits.
              </p>
              <div className={styles.heroActions}>
                <Link className={styles.btnPrimary} to="/docs/intro">
                  Get started
                </Link>
                <a
                  className={styles.btnSecondary}
                  href="https://github.com/joel-prins/PIM-Monitor"
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  View on GitHub
                </a>
                <span className={styles.heroTag}>v{APP_VERSION} · MIT</span>
              </div>
            </div>
            <GitLog />
          </div>

          <div className={styles.heroRight}>
            <NotificationCard />
            <DiffPanel />
          </div>
        </div>
      </main>
    </Layout>
  );
}
