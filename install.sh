sudo tee /root/agentstack-install.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
# ============================================================
#  ONE-SHOT: syadagentic  ->  skills Hermes  ->  Unlock-Hermes
#  Ubuntu/Debian. Idempotent. Log: /var/log/agentstack-install.log
# ============================================================
set -Eeuo pipefail

REPO1="https://github.com/Sekolah76/syadagentic.git"
REPO2="https://github.com/KorekKayu/Unlock-Hermes.git"
BASE="/opt/agentstack"
SRC1="$BASE/syadagentic"
SRC2="$BASE/unlock-hermes"
LOG="/var/log/agentstack-install.log"

C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_C='\033[1;36m'; C_0='\033[0m'
step(){ echo -e "\n${C_C}==> $*${C_0}"; }
ok(){   echo -e "${C_G}[OK]${C_0} $*"; }
warn(){ echo -e "${C_Y}[!]${C_0} $*"; }
die(){  echo -e "${C_R}[X]${C_0} $*" >&2; exit 1; }
trap 'die "gagal di baris $LINENO — cek $LOG"' ERR

mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

# ---------- 0. PREFLIGHT ----------
step "0/7 preflight"
[ "$(id -u)" -eq 0 ] || die "jalankan sebagai root: sudo bash $0"
RUN_USER="${SUDO_USER:-root}"
ORIG_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
[ -n "$ORIG_HOME" ] && [ -d "$ORIG_HOME" ] || die "home untuk user '$RUN_USER' tidak ditemukan"
export HOME="$ORIG_HOME"
export HERMES_HOME="${HERMES_HOME:-$ORIG_HOME/.hermes}"
SKILLS_DIR="$HERMES_HOME/skills"
export DEBIAN_FRONTEND=noninteractive

. /etc/os-release 2>/dev/null || true
case "${ID:-}:${ID_LIKE:-}" in
  *ubuntu*|*debian*) ok "distro: ${PRETTY_NAME:-unknown}" ;;
  *) warn "distro ${PRETTY_NAME:-unknown} belum diuji — lanjut hati-hati" ;;
esac

apt-get update -qq
apt-get install -y -qq git curl rsync python3 python3-yaml ca-certificates >/dev/null
ok "dependensi siap (git, rsync, python3, pyyaml)"

command -v hermes >/dev/null 2>&1 || die "CLI 'hermes' tidak ada di PATH. Install Hermes Agent dulu, lalu ulangi."
[ -d "$HERMES_HOME" ] || die "$HERMES_HOME tidak ada — Hermes belum pernah diinisialisasi user '$RUN_USER'."
ok "hermes: $(command -v hermes) | HERMES_HOME: $HERMES_HOME"

mkdir -p "$BASE"

# ---------- helper ----------
slugify(){ tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' '-' | sed 's/-\+/-/g; s/^-//; s/-$//'; }
fm_name(){ sed -n '/^---$/,/^---$/p' "$1" 2>/dev/null | grep -m1 -E '^name:' | sed 's/^name:[[:space:]]*//' | slugify; }
gen_skill_md(){
  local dir="$1" slug="$2" label="$3" desc
  desc="$(find "$dir" -maxdepth 1 -type f -name '*.md' ! -name 'SKILL.md' | head -1 | xargs -r grep -m1 -E '^[^#[:space:]]' 2>/dev/null | tr -d '"' | cut -c1-160)"
  [ -n "${desc:-}" ] || desc="Referensi hasil impor otomatis dari arsenal-skills/$label"
  cat > "$dir/SKILL.md" <<MD
---
name: $slug
description: $desc
category: syadagentic
source: arsenal-skills/$label
---

# $label

Referensi hasil impor otomatis dari \`arsenal-skills/$label\`.
File pendamping ada di folder ini — baca sesuai kebutuhan task.
MD
}

# ---------- 1. REPO 1 ----------
step "1/7 clone repo 1 (syadagentic)"
if [ -d "$SRC1/.git" ]; then git -C "$SRC1" pull --ff-only -q && ok "repo 1 di-update"
else git clone -q --depth 1 "$REPO1" "$SRC1" && ok "repo 1 di-clone"; fi
[ -f "$SRC1/install.sh" ] || die "install.sh tidak ditemukan di repo 1"

# ---------- 2. INSTALL REPO 1 ----------
step "2/7 jalankan installer repo 1"
cd "$SRC1"
SYADAGENTIC_DIR="$SRC1" bash install.sh --dir "$SRC1"
ok "installer repo 1 selesai"

# ---------- 3. INSTRUKSI LANJUTAN REPO 1 ----------
step "3/7 instruksi lanjutan repo 1 (system prompt + test suite)"
hermes config set agent.system_prompt "$(cat "$SRC1/SOUL.md")" && ok "agent.system_prompt di-set dari SOUL.md"
if [ -f "$SRC1/tests/run_tests.py" ]; then
  python3 "$SRC1/tests/run_tests.py" || warn "test suite repo 1 ada yang gagal (tidak fatal)"
else warn "tests/run_tests.py tidak ada — dilewati"; fi

# ---------- 4. COPY ARSENAL SKILLS ----------
step "4/7 copy arsenal-skills -> $SKILLS_DIR"
[ -d "$SRC1/arsenal-skills" ] || die "arsenal-skills tidak ada di repo 1"
mkdir -p "$SKILLS_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
N_SKILL=0

for d in "$SRC1"/arsenal-skills/*/; do
  [ -d "$d" ] || continue
  label="$(basename "$d")"
  if [ -f "$d/SKILL.md" ]; then slug="$(fm_name "$d/SKILL.md")"; fi
  [ -n "${slug:-}" ] || slug="$(printf '%s' "$label" | slugify)"
  [ -n "$slug" ] || continue
  target="$SKILLS_DIR/$slug"
  if [ -d "$target" ]; then mv "$target" "$target.bak-$STAMP"; fi
  mkdir -p "$target"
  rsync -a "$d" "$target/"
  [ -f "$target/SKILL.md" ] || gen_skill_md "$target" "$slug" "$label"
  N_SKILL=$((N_SKILL+1))
done

# file lepas di root arsenal-skills -> satu skill referensi
if find "$SRC1/arsenal-skills" -maxdepth 1 -type f | grep -q .; then
  root_skill="$SKILLS_DIR/syadagentic-arsenal-reference"
  mkdir -p "$root_skill"
  find "$SRC1/arsenal-skills" -maxdepth 1 -type f -exec cp -n {} "$root_skill/" \;
  [ -f "$root_skill/SKILL.md" ] || gen_skill_md "$root_skill" "syadagentic-arsenal-reference" "root arsenal-skills"
  N_SKILL=$((N_SKILL+1))
fi
ok "$N_SKILL skill terpasang di $SKILLS_DIR"

# ---------- 5. VERIFIKASI SKILL AKTIF ----------
step "5/7 verifikasi skill Hermes aktif"
N_SKILLMD="$(find "$SKILLS_DIR" -maxdepth 2 -name SKILL.md | wc -l | tr -d ' ')"
echo "    SKILL.md terdeteksi: $N_SKILLMD"
LIST="$(timeout 120 hermes skills list 2>&1 || true)"
if printf '%s' "$LIST" | grep -qiE 'hermes-guardrail-bypass|syadagentic'; then
  ok "skill TERDAFTAR di hermes skills list"
  printf '%s\n' "$LIST" | grep -iE 'hermes-guardrail-bypass|syadagentic' | head -10 | sed 's/^/    /'
elif [ -z "$LIST" ]; then
  warn "hermes skills list kosong/gagal — verifikasi via file ($N_SKILLMD SKILL.md)"
else
  warn "skill ada di disk tapi belum muncul di 'hermes skills list'"
fi
[ "$N_SKILLMD" -ge 5 ] || die "skill tidak aktif (hanya $N_SKILLMD SKILL.md) — repo 2 tidak dijalankan"
if [ -n "$LIST" ] && ! printf '%s' "$LIST" | grep -qiE 'hermes-guardrail-bypass|syadagentic'; then
  die "skill belum terdaftar oleh Hermes — repo 2 tidak dijalankan. Cek manual: hermes skills list"
fi
ok "gate verifikasi lolos — lanjut repo 2"

# ---------- 6. REPO 2 ----------
step "6/7 clone + install repo 2 (Unlock-Hermes)"
if [ -d "$SRC2/.git" ]; then git -C "$SRC2" pull --ff-only -q && ok "repo 2 di-update"
else git clone -q --depth 1 "$REPO2" "$SRC2" && ok "repo 2 di-clone"; fi
cd "$SRC2"
chmod +x unlock.sh 2>/dev/null || true
python3 unlock.py -y
ok "patcher repo 2 selesai"

step "6b/7 status + audit runtime"
python3 unlock.py --status || warn "--status gagal"
python3 unlock.py --audit  || warn "--audit gagal"

# ---------- 7. LAPORAN ----------
step "7/7 ringkasan"
cat <<SUM

  Repo 1      : $SRC1 (framework di $SRC1, system_prompt dari SOUL.md)
  Skills      : $SKILLS_DIR ($N_SKILL skill, $N_SKILLMD SKILL.md)
  Repo 2      : $SRC2 (guardrail dipatch, HACKMODE + prefill terpasang)
  Backup SOUL : $HERMES_HOME/SOUL.md.bak.* (dibuat oleh patcher)
  Log         : $LOG

  Cek ulang kapan saja:
    python3 $SRC2/unlock.py --status
    hermes skills list | grep -i syadagentic
  Ulangi setelah 'hermes update':
    python3 $SRC2/unlock.py -y
SUM
ok "SELESAI"
EOF
sudo bash /root/agentstack-install.sh