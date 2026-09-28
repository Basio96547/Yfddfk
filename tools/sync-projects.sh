#!/usr/bin/env bash
# sync-projects.sh — يجعل كل نسخة محلية من مشاريعك مطابقة لآخر نسخة على GitHub، في مكانها.
#
# يبحث في الجهاز عن كل مجلد مربوط بمستودع لصاحب الحساب على GitHub، وعن المجلدات العادية
# التي تحمل اسم أحد مستودعاته، ويجعل كلًّا منها في مكانه مطابقًا للفرع الافتراضي (main)
# على GitHub، ثم يذكر المستودعات غير الموجودة على الجهاز.
# صُمّم لـ Git Bash على Windows، ويعمل كذلك على Linux (bash 4.4+ وgit 2.26+).
#
# الاستخدام:
#   bash sync-projects.sh --dry-run     معاينة ما سيحدث لكل مشروع بلا أي تعديل
#   bash sync-projects.sh               مطابقة النسخ المحلية مع GitHub
#
# لا يُحذف شيء:
#   - كل ملف عدّلته محليًا يُحفظ في git stash قبل المطابقة (استرجاعه: git stash pop)
#   - كل commit غير مرفوع يُحفظ في فرع sync-backup/<الوقت>/<الفرع>
#   - الفرع الذي كنت عليه (إن لم يكن الفرع الافتراضي) يبقى محليًا كما هو
#   - الملفات المحلية الإضافية غير الموجودة على GitHub تبقى في مكانها (--clean يحفظها في stash)
#   - الملفات المتجاهَلة في .gitignore مثل .env وnode_modules لا تُمسّ
# المجلد العادي (غير المربوط بـ git) الذي يحمل اسم مستودع يُسأل عنه قبل ربطه.
#
# الخيارات:
#   --dry-run          اعرض الخطة فقط (يجلب من GitHub لكنه لا يغيّر ملفاتك).
#   --clean            طابق حرفيًا: احفظ في stash أيضًا الملفات الإضافية غير الموجودة على GitHub.
#   --adopt            اربط دون سؤال كل مجلد عادي يحمل اسم مستودع (راجع --dry-run قبله).
#   --safe             تحديث محافظ بدل المطابقة: fast-forward فقط على الفرع الحالي،
#                      ويتخطّى ما فيه تعديلات أو commits محلية متعارضة.
#   --only a,b         اقصر العمل على هذه المستودعات (بأسمائها على GitHub).
#   --clone-missing    استنسخ مستودعاتك غير الموجودة على الجهاز إلى --clone-dir.
#   --clone-dir DIR    مكان الاستنساخ (الافتراضي: ~/Desktop/GitHub).
#   --deps             ثبّت الحزم (npm/pnpm/yarn/bun) حيث تغيّرت الاعتماديات أو رُبط المشروع.
#   --root DIR         ابحث في هذا المجلد بدل الافتراضي (يتكرر). الافتراضي: مجلد المستخدم،
#                      وعلى Windows أيضًا C:\ (بلا مجلدات النظام) والأقراص D: وما بعدها.
#   --depth N          أقصى عمق للبحث (الافتراضي 6).
#   --owner NAME       صاحب المستودعات على GitHub (الافتراضي Basio96547).
#   --list FILE        خذ أسماء المستودعات من ملف (اسم في كل سطر) بدل سؤال GitHub.
#   -h, --help         هذه المساعدة.

set -uo pipefail

if [ $(( ${BASH_VERSINFO[0]:-0} * 100 + ${BASH_VERSINFO[1]:-0} )) -lt 404 ]; then
	echo "يلزم bash 4.4 أو أحدث (Git Bash على Windows مناسب)." >&2
	exit 1
fi
command -v git >/dev/null 2>&1 || { echo "git غير مثبت." >&2; exit 1; }
read -r GIT_MAJOR GIT_MINOR < <(git version | sed -E 's/^git version ([0-9]+)\.([0-9]+).*/\1 \2/')
if [ $(( GIT_MAJOR * 100 + GIT_MINOR )) -lt 226 ]; then
	echo "يلزم git 2.26 أو أحدث — حدّث Git for Windows من https://git-scm.com" >&2
	exit 1
fi

OWNER=Basio96547
MODE=mirror
DRY_RUN=0
CLEAN=0
ADOPT=0
CLONE_MISSING=0
DEPS=0
CLONE_DIR="$HOME/Desktop/GitHub"
DEPTH=6
ONLY=""
LIST_FILE=""
ROOTS=()

usage() { sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; }

while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRY_RUN=1 ;;
		--clean) CLEAN=1 ;;
		--adopt) ADOPT=1 ;;
		--safe) MODE=safe ;;
		--clone-missing) CLONE_MISSING=1 ;;
		--clone-dir) CLONE_DIR="${2:?--clone-dir يحتاج مسارًا}"; shift ;;
		--deps) DEPS=1 ;;
		--only) ONLY=",${2:?--only يحتاج أسماء},"; ONLY=${ONLY// /}; shift ;;
		--root)
			[ -d "${2:?--root يحتاج مسارًا}" ] || { echo "المجلد غير موجود: $2" >&2; exit 2; }
			ROOTS+=("$(cd "$2" && pwd)"); shift ;;
		--depth)
			[[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "--depth يحتاج رقمًا" >&2; exit 2; }
			DEPTH=$2; shift ;;
		--owner) OWNER="${2:?--owner يحتاج اسمًا}"; shift ;;
		--list) LIST_FILE="${2:?--list يحتاج ملفًا}"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "خيار غير معروف: $1" >&2; usage; exit 2 ;;
	esac
	shift
done
if [ "$MODE" = safe ] && { [ "$CLEAN" = 1 ] || [ "$ADOPT" = 1 ]; }; then
	echo "--clean و--adopt لا يعملان مع --safe" >&2
	exit 2
fi

IS_WINDOWS=""
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;; esac

if [ ${#ROOTS[@]} -eq 0 ]; then
	ROOTS=("$HOME")
	if [ -n "$IS_WINDOWS" ]; then
		for d in /c /{d..z}; do [ -d "$d/" ] && ROOTS+=("$d"); done
	fi
fi

# مجلدات لا تحوي مشاريع أو ثقيلة البحث (المجلدات المخفية تُتخطّى كلها عدا .git)
# shellcheck disable=SC2016  # $Recycle.Bin اسم حرفي لا متغير
PRUNE_NAMES=(node_modules AppData Users Windows 'Program Files' 'Program Files (x86)'
	ProgramData '$Recycle.Bin' '$RECYCLE.BIN' 'System Volume Information' Recovery PerfLogs
	Library venv __pycache__)

TS=$(date +%Y%m%d-%H%M%S)
WORK=$(mktemp -d)
ERRF="$WORK/err"
trap 'rm -rf "$WORK"' EXIT
ANY_STASH=""
ANY_BACKUP=""

if [ -t 1 ]; then
	C_OK=$'\e[32m' C_WARN=$'\e[33m' C_ERR=$'\e[31m' C_DIM=$'\e[2m' C_HEAD=$'\e[1;36m' C_END=$'\e[0m'
else
	C_OK="" C_WARN="" C_ERR="" C_DIM="" C_HEAD="" C_END=""
fi

disp() {
	if [ -n "$IS_WINDOWS" ] && command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}

say() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_END"; }

# OK: مطابق مسبقًا · UPD: طوبق/حُدّث · LINK: رُبط مجلد عادي · NEW: استُنسخ
# SKIP: تُخطّي · MISS: غير موجود محليًا · ERR: خطأ
RESULTS=()
report() {
	local kind=$1 name=$2 dir=$3 msg=$4 color=$C_DIM
	case $kind in
		UPD|LINK|NEW) color=$C_OK ;;
		SKIP|MISS) color=$C_WARN ;;
		ERR) color=$C_ERR ;;
	esac
	printf '%s[%-4s]%s %s — %s\n' "$color" "$kind" "$C_END" "$name" "$msg"
	[ -n "$dir" ] && printf '        %s%s%s\n' "$C_DIM" "$(disp "$dir")" "$C_END"
	RESULTS+=("$kind"$'\t'"$name"$'\t'"$msg")
}

# أوضح سطر خطأ من آخر أمر
last_err() {
	grep -m1 -E '^(error|fatal):' "$ERRF" 2>/dev/null || grep -v '^[[:space:]]*$' "$ERRF" 2>/dev/null | tail -n 1
}

has_ref() { git -C "$1" rev-parse -q --verify "$2^{commit}" >/dev/null 2>&1; }
is_anc() { git -C "$1" merge-base --is-ancestor "$2" "$3" 2>/dev/null; }
in_only() { [ -z "$ONLY" ] || [[ "${ONLY,,}" == *",${1,,},"* ]]; }
count_z() { tr -cd '\0' <"$1" | wc -c | tr -d ' '; }
last_commit() { git -C "$1" log -1 --date=short --format='%s (%cd)' 2>/dev/null; }

# اسم المستودع من رابط GitHub إن كان لصاحب الحساب، وإلا فشل
repo_from_url() {
	local re="github\.com[:/]+${OWNER}/([^/]+)/?$"
	shopt -s nocasematch
	if [[ $1 =~ $re ]]; then
		shopt -u nocasematch
		printf '%s\n' "${BASH_REMATCH[1]%.git}"
		return 0
	fi
	shopt -u nocasematch
	return 1
}

# يطبع (مفصولة بـ NUL) كل مجلد .git، وكل مجلد اسمه اسم أحد المستودعات
find_dirs() {
	local -a prune=(-name '.*') match=()
	local n root
	for n in "${PRUNE_NAMES[@]}"; do prune+=(-o -name "$n"); done
	for n in "$@"; do match+=(-o -iname "$n"); done
	for root in "${ROOTS[@]}"; do
		[ -d "$root" ] || continue
		say "… البحث في $(disp "$root")" >&2
		if [ ${#match[@]} -gt 0 ]; then
			find "$root" -mindepth 1 -maxdepth "$DEPTH" -type d \( \( -name .git -print0 -prune \) \
				-o \( \( "${prune[@]}" \) -prune \) -o \( \( "${match[@]:1}" \) -print0 \) \) 2>/dev/null
		else
			find "$root" -mindepth 1 -maxdepth "$DEPTH" -type d \( \( -name .git -print0 -prune \) \
				-o \( \( "${prune[@]}" \) -prune \) \) 2>/dev/null
		fi
	done
}

# أقرب مجلد (من المجلد نفسه صعودًا حتى جذر المستودع) فيه lockfile، وإلا المجلد نفسه
lock_dir_for() {
	local root=$1 d=$2 cur=$2
	while :; do
		if [ -f "$root/$cur/package-lock.json" ] || [ -f "$root/$cur/pnpm-lock.yaml" ] ||
			[ -f "$root/$cur/yarn.lock" ] || [ -f "$root/$cur/bun.lockb" ] || [ -f "$root/$cur/bun.lock" ]; then
			printf '%s\n' "$cur"; return
		fi
		[ "$cur" = . ] && break
		cur=$(dirname "$cur")
	done
	printf '%s\n' "$d"
}

install_deps() {
	local d=$1
	local -a cmd
	if [ -f "$d/pnpm-lock.yaml" ]; then cmd=(pnpm install --frozen-lockfile)
	elif [ -f "$d/yarn.lock" ]; then cmd=(yarn install)
	elif [ -f "$d/bun.lockb" ] || [ -f "$d/bun.lock" ]; then cmd=(bun install)
	elif [ -f "$d/package-lock.json" ]; then cmd=(npm ci --no-audit --no-fund)
	else cmd=(npm install --no-audit --no-fund)
	fi
	if ! command -v "${cmd[0]}" >/dev/null 2>&1; then
		echo "error: ${cmd[0]} غير مثبت" >"$ERRF"; return 1
	fi
	(cd "$d" && "${cmd[@]}") >"$ERRF" 2>&1
}

# يثبّت الحزم (أو يذكر الحاجة لذلك) في المجلدات المعطاة؛ يضيف النتيجة إلى msg عند المستدعي
handle_deps() {
	local root=$1 dirs=$2 d done_list="" failed=""
	local -a todo=()
	while IFS= read -r d; do
		[ -n "$d" ] && [ -f "$root/$d/package.json" ] || continue
		d=$(lock_dir_for "$root" "$d")
		[[ " ${todo[*]} " == *" $d "* ]] || todo+=("$d")
	done <<<"$dirs"
	[ ${#todo[@]} -eq 0 ] && return
	if [ "$DEPS" = 1 ] && [ "$DRY_RUN" = 0 ]; then
		for d in "${todo[@]}"; do
			say "  … تثبيت الحزم في $d" >&2
			if install_deps "$root/$d"; then done_list+=" $d"; else failed+=" $d ($(last_err))"; fi
		done
		[ -n "$done_list" ] && msg+=" | ثُبّتت الحزم في:$done_list"
		[ -n "$failed" ] && msg+=" | فشل تثبيت الحزم في:$failed"
	else
		msg+=" | الاعتماديات تغيّرت في: ${todo[*]} — ثبّتها (npm install) أو أعد التشغيل مع --deps"
	fi
}

deps_after_update() {
	local dir=$1 old=$2 new=$3 dirs
	[ "$old" = "$new" ] && return
	dirs=$(git -C "$dir" diff --name-only "$old" "$new" 2>/dev/null |
		grep -E '(^|/)(package\.json|package-lock\.json|npm-shrinkwrap\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lockb?)$' |
		sed -E 's#(^|/)[^/]+$##; s#^$#.#' | sort -u)
	[ -n "$dirs" ] && handle_deps "$dir" "$dirs"
}

# أحدث فرع على GitHub إن كان فيه عمل غير مدموج في الفرع الذي نتبعه
newer_branch_hint() {
	local dir=$1 remote=$2 target=$3 ref date
	read -r ref date < <(git -C "$dir" for-each-ref --sort=-committerdate \
		--format='%(refname) %(committerdate:short)' "refs/remotes/$remote/" |
		grep -v "^refs/remotes/$remote/HEAD " | head -n 1)
	ref=${ref#refs/remotes/}
	[ -n "$ref" ] && [ "$ref" != "$target" ] || return 0
	is_anc "$dir" "$ref" "$target" && return 0
	printf 'على GitHub فرع أحدث غير مدموج: %s (%s)' "${ref#"$remote"/}" "$date"
}

backup_branch() {
	local dir=$1 rev=$2 label=$3 b="sync-backup/$TS/$3"
	git -C "$dir" branch -q "$b" "$rev" 2>"$ERRF" || return 1
	backup+=" $b"
	ANY_BACKUP=1
}

update_submodules() {
	[ -f "$1/.gitmodules" ] || return 0
	git -C "$1" submodule update --init --recursive --quiet 2>"$ERRF" || msg+=" | تعذّر تحديث submodules: $(last_err)"
}

# يكمل رسالة النتيجة ويطبعها؛ يقرأ من المستدعي: msg left_branch stashed backup n_extra hint
finish_update() {
	local dir=$1 name=$2 kind=$3 old=$4 label=$5 new
	new=$(git -C "$dir" rev-parse HEAD)
	if [ -z "$old" ]; then
		msg="$label — آخر commit: $(last_commit "$dir")$msg"
		[ -f "$dir/package.json" ] && handle_deps "$dir" "."
	else
		local count
		count=$(git -C "$dir" rev-list --count "$old..$new")
		if [ "$count" -gt 0 ]; then
			msg="$label: $count commit جديد — آخرها: $(last_commit "$dir")$msg"
		else
			msg="$label — آخر commit: $(last_commit "$dir")$msg"
		fi
		deps_after_update "$dir" "$old" "$new"
	fi
	[ -n "$left_branch" ] && msg+=" | الفرع $left_branch باقٍ محليًا كما هو"
	[ -n "$stashed" ] && msg+=" | تعديلاتك المحلية محفوظة في stash باسم \"sync-projects $TS\""
	[ -n "$backup" ] && msg+=" | الـ commits غير المرفوعة محفوظة في:$backup"
	[ "$n_extra" -gt 0 ] && msg+=" | $n_extra ملف محلي إضافي غير موجود على GitHub باقٍ كما هو"
	[ -n "$hint" ] && msg+=" | $hint"
	report "$kind" "$name" "$dir" "$msg"
}

# وضع المطابقة: النسخة المحلية = الفرع الافتراضي على GitHub، بعد حفظ كل ما هو محلي
mirror_repo() {
	local dir=$1 remote=$2 name=$3 def=$4 kind=$5
	local -a g=(git -C "$dir") ident=()
	local target="$remote/$def" branch unborn="" old="" behind=0 hint msg="" stashed="" backup=""
	local left_branch="" def_ahead="" lost_detached="" n_changed n_stash_untracked n_extra

	branch=$("${g[@]}" symbolic-ref -q --short HEAD) || branch=""
	has_ref "$dir" HEAD || unborn=1
	hint=$(newer_branch_hint "$dir" "$remote" "$target")

	if [ -n "$unborn" ]; then
		if [ "$DRY_RUN" = 1 ]; then
			report "$kind" "$name" "$dir" "سيُطابَق مع $def على GitHub — الملفات المحلية المختلفة تُحفظ في stash"
			return
		fi
		# اجعل الفرع يشير إلى GitHub مع إبقاء الملفات كما هي، فتظهر فروقها كتعديلات تُحفظ في stash
		"${g[@]}" symbolic-ref HEAD "refs/heads/$def"
		if ! "${g[@]}" reset -q "$target" 2>"$ERRF"; then
			report ERR "$name" "$dir" "$(last_err)"
			return
		fi
		# .gitignore الخاص بالمستودع قد لا يكون موجودًا محليًا بعد؛ طبّقه حتى لا تُحفظ node_modules وأمثالها
		if [ -d "$dir/.git" ]; then
			mkdir -p "$dir/.git/info"
			{ echo "node_modules/"; "${g[@]}" show "$target:.gitignore" 2>/dev/null; echo; } >>"$dir/.git/info/exclude"
		fi
		branch=$def
	else
		old=$("${g[@]}" rev-parse HEAD)
		behind=$("${g[@]}" rev-list --count "HEAD..$target")
	fi

	{ "${g[@]}" diff --name-only --no-renames -z HEAD; "${g[@]}" diff --cached --name-only --no-renames -z HEAD; } 2>/dev/null |
		LC_ALL=C sort -zu >"$WORK/changed"
	"${g[@]}" ls-files --others --exclude-standard -z 2>/dev/null | LC_ALL=C sort -z >"$WORK/untracked"
	"${g[@]}" ls-tree -r --name-only -z "$target" 2>/dev/null | LC_ALL=C sort -z >"$WORK/tree"
	if [ "$CLEAN" = 1 ]; then
		cp "$WORK/untracked" "$WORK/stash_untracked"
	else
		# ملفات غير متتبَّعة في مسارات موجودة على GitHub: تُحفظ حتى تحلّ نسخة GitHub مكانها
		LC_ALL=C comm -12 -z "$WORK/untracked" "$WORK/tree" >"$WORK/stash_untracked"
	fi
	n_changed=$(count_z "$WORK/changed")
	n_stash_untracked=$(count_z "$WORK/stash_untracked")
	n_extra=$(( $(count_z "$WORK/untracked") - n_stash_untracked ))

	if has_ref "$dir" "refs/heads/$def" && ! is_anc "$dir" "refs/heads/$def" "$target"; then
		def_ahead=$("${g[@]}" rev-list --count "$target..refs/heads/$def")
	fi
	[ -z "$branch" ] && ! is_anc "$dir" HEAD "$target" && lost_detached=1
	[ -n "$branch" ] && [ "$branch" != "$def" ] && left_branch=$branch

	if [ -z "$unborn" ] && [ "$branch" = "$def" ] && [ "$old" = "$("${g[@]}" rev-parse "$target")" ] &&
		[ "$n_changed" -eq 0 ] && [ "$n_stash_untracked" -eq 0 ]; then
		if [ "$DRY_RUN" = 0 ] && [ "$("${g[@]}" rev-parse -q --abbrev-ref '@{upstream}' 2>/dev/null)" != "$target" ]; then
			"${g[@]}" branch -q --set-upstream-to="$target" 2>/dev/null
		fi
		msg="مطابق لـ GitHub ($def)"
		[ "$n_extra" -gt 0 ] && msg+=" — و$n_extra ملف محلي إضافي غير موجود على GitHub (باقٍ كما هو)"
		[ -n "$hint" ] && msg+=" | $hint"
		report OK "$name" "$dir" "$msg"
		return
	fi

	if [ "$DRY_RUN" = 1 ]; then
		msg="سيُطابَق مع $def على GitHub"
		[ "$behind" -gt 0 ] && msg+=": $behind commit جديد"
		[ -n "$left_branch" ] && msg+=" | ينتقل من الفرع $left_branch (يبقى محليًا)"
		[ "$n_changed" -gt 0 ] && msg+=" | $n_changed ملف معدّل محليًا يُحفظ في stash"
		[ "$n_stash_untracked" -gt 0 ] && msg+=" | $n_stash_untracked ملف غير متتبَّع يُحفظ في stash"
		[ -n "$def_ahead" ] && msg+=" | $def_ahead commit غير مرفوع في $def يُحفظ في فرع احتياطي"
		[ -n "$lost_detached" ] && msg+=" | commits الـ HEAD المنفصل تُحفظ في فرع احتياطي"
		[ "$n_extra" -gt 0 ] && msg+=" | $n_extra ملف محلي إضافي يبقى كما هو"
		[ -n "$hint" ] && msg+=" | $hint"
		report UPD "$name" "$dir" "$msg"
		return
	fi

	cat "$WORK/changed" "$WORK/stash_untracked" >"$WORK/stash"
	if [ -s "$WORK/stash" ]; then
		# stash يحتاج هوية git؛ إن لم تكن مضبوطة نستعمل هوية مؤقتة لهذا الأمر فقط
		git -C "$dir" config user.email >/dev/null 2>&1 || ident=(-c user.name=sync-projects -c user.email=sync-projects@localhost)
		if ! GIT_LITERAL_PATHSPECS=1 git "${ident[@]}" -C "$dir" stash push --include-untracked -q \
			-m "sync-projects $TS" --pathspec-from-file=- --pathspec-file-nul <"$WORK/stash" 2>"$ERRF"; then
			report ERR "$name" "$dir" "تعذّر حفظ التعديلات المحلية في stash — لم يُغيَّر شيء: $(last_err)"
			return
		fi
		stashed=1 ANY_STASH=1
	fi
	if [ -n "$def_ahead" ] && ! backup_branch "$dir" "refs/heads/$def" "$def"; then
		report ERR "$name" "$dir" "تعذّر إنشاء فرع احتياطي: $(last_err)"
		return
	fi
	if [ -n "$lost_detached" ] && ! backup_branch "$dir" HEAD detached; then
		report ERR "$name" "$dir" "تعذّر إنشاء فرع احتياطي: $(last_err)"
		return
	fi
	if ! "${g[@]}" checkout -q -B "$def" --track "$target" 2>"$ERRF" ||
		! "${g[@]}" reset -q --hard "$target" 2>"$ERRF"; then
		report ERR "$name" "$dir" "تعذّرت المطابقة: $(last_err)"
		return
	fi
	update_submodules "$dir"

	# تحقّق أن النسخة صارت مطابقة فعلًا
	if [ "$("${g[@]}" rev-parse HEAD)" != "$("${g[@]}" rev-parse "$target")" ] ||
		[ -n "$("${g[@]}" status --porcelain --untracked-files=no --ignore-submodules=dirty 2>/dev/null)" ]; then
		report ERR "$name" "$dir" "انتهت المطابقة لكن ما زالت هناك فروق — راجع git status في المجلد"
		return
	fi

	if [ -n "$unborn" ]; then
		finish_update "$dir" "$name" "$kind" "" "رُبط بـ GitHub وطوبق مع $def"
	else
		finish_update "$dir" "$name" "$kind" "$old" "طوبق مع $def"
	fi
}

# وضع --safe: fast-forward فقط، ويتخطّى ما لا يُحدَّث بأمان
safe_repo() {
	local dir=$1 remote=$2 name=$3 def=$4
	local -a g=(git -C "$dir")
	local branch up target="" switch="" dirty="" old ahead behind hint msg="" stashed="" backup=""
	local left_branch="" n_extra=0 reasons=""

	if ! has_ref "$dir" HEAD; then
		report SKIP "$name" "$dir" "المستودع المحلي بلا أي commit — شغّل السكربت بدون --safe لمطابقته"
		return
	fi
	branch=$("${g[@]}" symbolic-ref -q --short HEAD) || branch=""
	if [ -n "$branch" ]; then
		up=$("${g[@]}" rev-parse -q --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || up=""
		if [ -n "$up" ] && [ "${up%%/*}" = "$remote" ] && has_ref "$dir" "refs/remotes/$up"; then
			target=$up
		elif has_ref "$dir" "refs/remotes/$remote/$branch"; then
			target="$remote/$branch"
		fi
	fi
	if [ -z "$target" ]; then
		# فرع بلا مقابل على GitHub (غالبًا دُمج وحُذف) أو HEAD منفصل: الوجهة هي الفرع الافتراضي
		if [ -z "$def" ]; then
			report SKIP "$name" "$dir" "لا يوجد فرع افتراضي على GitHub (المستودع فارغ؟)"
			return
		fi
		target="$remote/$def" switch=$def
	elif [ -n "$def" ] && [ "$branch" != "$def" ] &&
		is_anc "$dir" HEAD "$remote/$def" && is_anc "$dir" "$target" "$remote/$def"; then
		# فرع انتهى: كل ما فيه محليًا وعلى GitHub موجود في الفرع الافتراضي
		target="$remote/$def" switch=$def
	fi

	[ -n "$("${g[@]}" status --porcelain --untracked-files=no 2>/dev/null)" ] && dirty=1
	old=$("${g[@]}" rev-parse HEAD)
	hint=$(newer_branch_hint "$dir" "$remote" "$target")

	if [ -n "$switch" ]; then
		local from=${branch:-"HEAD منفصل"}
		[ -n "$dirty" ] && reasons+="تعديلات محلية غير محفوظة؛ "
		is_anc "$dir" HEAD "$target" || reasons+="$from فيه commits غير موجودة في $def على GitHub؛ "
		if has_ref "$dir" "refs/heads/$switch" && ! is_anc "$dir" "refs/heads/$switch" "$target"; then
			reasons+="فرع $switch المحلي فيه commits غير مرفوعة؛ "
		fi
		if [ -n "$reasons" ]; then
			report SKIP "$name" "$dir" "${reasons%؛ } — لم يُلمس (بدون --safe يُطابَق مع GitHub بعد حفظ نسخة احتياطية)"
			return
		fi
		if [ "$DRY_RUN" = 1 ]; then
			msg="سينتقل من $from إلى $def ويحدّثه"
			[ -n "$hint" ] && msg+=" | $hint"
			report UPD "$name" "$dir" "$msg"
			return
		fi
		if ! "${g[@]}" checkout -q -B "$switch" --track "$target" 2>"$ERRF"; then
			report SKIP "$name" "$dir" "تعذّر الانتقال إلى $def: $(last_err)"
			return
		fi
		left_branch=$branch
		update_submodules "$dir"
		finish_update "$dir" "$name" UPD "$old" "حُدّث (انتقل إلى $def)"
		return
	fi

	if ! read -r ahead behind < <("${g[@]}" rev-list --left-right --count "HEAD...$target" 2>"$ERRF"); then
		report ERR "$name" "$dir" "$(last_err)"
		return
	fi
	if [ "$behind" -eq 0 ]; then
		msg="محدّث بالفعل ($branch)"
		[ "$ahead" -gt 0 ] && msg+=" — وفيه $ahead commit محلي غير مرفوع (git push)"
		[ -n "$dirty" ] && msg+=" — وفيه تعديلات محلية غير محفوظة"
		[ -n "$hint" ] && msg+=" | $hint"
		report OK "$name" "$dir" "$msg"
		return
	fi
	if [ "$ahead" -gt 0 ]; then
		report SKIP "$name" "$dir" "تباعد: $ahead commit محلي غير مرفوع و$behind جديد على GitHub — لم يُلمس (بدون --safe يُطابَق مع GitHub بعد حفظ نسخة احتياطية)"
		return
	fi
	if [ "$DRY_RUN" = 1 ]; then
		msg="سيُحدَّث ($branch): $behind commit جديد"
		[ -n "$dirty" ] && msg+=" — فيه تعديلات محلية؛ إن تعارضت مع التحديث فسيُتخطّى"
		[ -n "$hint" ] && msg+=" | $hint"
		report UPD "$name" "$dir" "$msg"
		return
	fi
	if ! "${g[@]}" merge -q --ff-only "$target" 2>"$ERRF"; then
		# git يسرد الملفات المتعارضة في أسطر تبدأ بمسافة
		local files
		files=$(grep -E '^[[:space:]]+[^[:space:]]' "$ERRF" | sed -E 's/^[[:space:]]+//' | head -n 5 | paste -sd ',' - | sed 's/,/، /g')
		[ -z "$files" ] && files=$(last_err)
		report SKIP "$name" "$dir" "تعديلات محلية تتعارض مع التحديث ($files) — لم يُلمس (بدون --safe تُحفظ في stash ثم يُطابَق)"
		return
	fi
	update_submodules "$dir"
	finish_update "$dir" "$name" UPD "$old" "حُدّث ($branch)"
}

sync_repo() {
	local dir=$1 remote=$2 name=$3 kind=${4:-UPD}
	local gd def
	gd=$(git -C "$dir" rev-parse --absolute-git-dir 2>"$ERRF") || { report ERR "$name" "$dir" "$(last_err)"; return; }
	if [ -e "$gd/MERGE_HEAD" ] || [ -e "$gd/CHERRY_PICK_HEAD" ] || [ -e "$gd/REVERT_HEAD" ] ||
		[ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]; then
		report SKIP "$name" "$dir" "فيه عملية merge/rebase لم تكتمل — أكملها أو ألغِها أولًا ثم أعد التشغيل"
		return
	fi
	if ! git -C "$dir" fetch --prune --quiet "$remote" 2>"$ERRF"; then
		report ERR "$name" "$dir" "فشل الجلب من GitHub: $(last_err)"
		return
	fi
	# الفرع الافتراضي كما هو الآن على GitHub
	git -C "$dir" remote set-head "$remote" --auto >/dev/null 2>&1
	def=$(git -C "$dir" symbolic-ref -q --short "refs/remotes/$remote/HEAD" 2>/dev/null) || def=""
	def=${def#"$remote"/}
	[ -n "$def" ] && ! has_ref "$dir" "refs/remotes/$remote/$def" && def=""

	if [ "$MODE" = safe ]; then
		safe_repo "$dir" "$remote" "$name" "$def"
	elif [ -z "$def" ]; then
		report SKIP "$name" "$dir" "لا يوجد فرع افتراضي على GitHub (المستودع فارغ؟)"
	else
		mirror_repo "$dir" "$remote" "$name" "$def" "$kind"
	fi
}

# مجلد عادي (أو مستودع git بلا remote) يحمل اسم مستودع: يُربط بـ GitHub ثم يُطابَق
adopt_dir() {
	local dir=$1 name=$2 created="" url r ans
	if [ -e "$dir/.git" ]; then
		if [ -n "$(git -C "$dir" remote 2>/dev/null)" ]; then
			while read -r _ url; do repo_from_url "$url" >/dev/null && return; done \
				< <(git -C "$dir" config --local --get-regexp '^remote\..*\.url$' 2>/dev/null)
			r=$(git -C "$dir" remote | head -n 1)
			report SKIP "$name" "$dir" "مجلد git بنفس الاسم لكنه مربوط بمستودع آخر: $(git -C "$dir" config --local --get "remote.$r.url" 2>/dev/null) — لم يُلمس"
			return
		fi
	fi
	if [ "$DRY_RUN" = 1 ]; then
		report LINK "$name" "$dir" "مجلد بنفس اسم المستودع غير مربوط بـ GitHub — سيُربط ويُطابَق (بعد موافقتك، أو مع --adopt)"
		return
	fi
	if [ "$ADOPT" = 0 ]; then
		if [ -t 0 ] && [ -r /dev/tty ]; then
			printf '\n%sالمجلد %s يحمل اسم مستودعك %s وغير مربوط بـ GitHub.%s\n' "$C_WARN" "$(disp "$dir")" "$name" "$C_END"
			printf 'أجعله مطابقًا لـ GitHub؟ (ملفاتك المختلفة تُحفظ في stash ولا تُحذف) [y/N] '
			read -r ans </dev/tty || ans=""
			case "$ans" in
				y|Y|yes|YES|ن|نعم) ;;
				*) report SKIP "$name" "$dir" "لم يُربط (اخترت لا)"; return ;;
			esac
		else
			report SKIP "$name" "$dir" "مجلد بنفس اسم المستودع غير مربوط بـ GitHub — أعد التشغيل في Git Bash لتُسأل عنه، أو مع --adopt"
			return
		fi
	fi
	if [ ! -e "$dir/.git" ]; then
		git -C "$dir" init -q 2>"$ERRF" || { report ERR "$name" "$dir" "تعذّر إنشاء git: $(last_err)"; return; }
		created=1
	fi
	if ! git -C "$dir" remote add origin "https://github.com/$OWNER/$name.git" 2>"$ERRF"; then
		report ERR "$name" "$dir" "$(last_err)"
		[ -n "$created" ] && rm -rf "$dir/.git"
		return
	fi
	sync_repo "$dir" origin "$name" LINK
	# إن فشل الربط أعِد المجلد كما كان
	case "${RESULTS[-1]%%$'\t'*}" in
		LINK|OK) ;;
		*) if [ -n "$created" ]; then rm -rf "$dir/.git"; else git -C "$dir" remote remove origin 2>/dev/null; fi ;;
	esac
}

clone_repo() {
	local name=$1 dest="$CLONE_DIR/$1" msg
	if [ -e "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
		report SKIP "$name" "$dest" "المجلد موجود وليس نسخة git من هذا المستودع — لم يُلمس"
		return
	fi
	if [ "$DRY_RUN" = 1 ]; then
		report NEW "$name" "$dest" "سيُستنسخ"
		return
	fi
	mkdir -p "$CLONE_DIR"
	say "… استنساخ $name" >&2
	if ! git clone --quiet --recurse-submodules "https://github.com/$OWNER/$name.git" "$dest" 2>"$ERRF"; then
		report ERR "$name" "$dest" "فشل الاستنساخ: $(last_err)"
		return
	fi
	msg="استُنسخ ($(git -C "$dest" symbolic-ref -q --short HEAD 2>/dev/null)) — آخر commit: $(last_commit "$dest")"
	[ -f "$dest/package.json" ] && handle_deps "$dest" "."
	report NEW "$name" "$dest" "$msg"
}

# أسماء مستودعات صاحب الحساب على GitHub (سطر لكل اسم)
REMOTE_LIST_NOTE=""
list_remote_repos() {
	if [ -n "$LIST_FILE" ]; then
		tr -d '\r' <"$LIST_FILE" | sed -E 's/#.*//; s/[[:space:]]+//g; s#.*/##; s/\.git$//' | grep -v '^$'
		return
	fi
	if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
		gh repo list "$OWNER" --limit 1000 --json name --jq '.[].name'
		return
	fi
	command -v curl >/dev/null 2>&1 || return 1
	local cred token page=1 out names url
	local -a auth=()
	# رمز الدخول الذي يحفظه Git Credential Manager لـ github.com (لا يُطبع ولا يُكتب في ملف)
	if [ -t 0 ]; then
		cred=$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null)
	else
		cred=$(printf 'protocol=https\nhost=github.com\n\n' | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null)
	fi
	token=$(printf '%s\n' "$cred" | sed -n 's/^password=//p')
	[ -n "$token" ] && auth=(-H "Authorization: Bearer $token")
	while :; do
		if [ -n "$token" ]; then
			url="https://api.github.com/user/repos?per_page=100&page=$page&affiliation=owner"
		else
			url="https://api.github.com/users/$OWNER/repos?per_page=100&page=$page"
		fi
		if ! out=$(curl -fsSL "${auth[@]}" "$url" 2>/dev/null); then
			if [ -n "$token" ] && [ "$page" = 1 ]; then
				# الرمز المحفوظ مرفوض: انسه وتابع بالمستودعات العامة
				printf '%s\n' "$cred" | git credential reject 2>/dev/null
				token="" auth=()
				continue
			fi
			return 1
		fi
		if [ "$page" = 1 ]; then
			if [ -n "$token" ]; then
				printf '%s\n' "$cred" | git credential approve 2>/dev/null
			else
				REMOTE_LIST_NOTE="بلا تسجيل دخول: القائمة تشمل المستودعات العامة فقط — سجّل الدخول (gh auth login) لتشمل الخاصة"
			fi
		fi
		names=$(printf '%s' "$out" | grep -o '"full_name": *"[^"]*"' | sed -E 's/.*"([^"]*)"$/\1/')
		[ -z "$names" ] && break
		printf '%s\n' "$names" | grep -i "^$OWNER/" | sed 's#.*/##'
		page=$((page + 1))
	done
}

# ─── التنفيذ ───────────────────────────────────────────────────────────────
printf '%sمطابقة مشاريع %s مع GitHub%s' "$C_HEAD" "$OWNER" "$C_END"
[ "$MODE" = safe ] && printf ' %s(--safe: تحديث محافظ)%s' "$C_WARN" "$C_END"
[ "$CLEAN" = 1 ] && printf ' %s(--clean)%s' "$C_WARN" "$C_END"
[ "$DRY_RUN" = 1 ] && printf ' %s(معاينة فقط — لن يتغيّر شيء)%s' "$C_WARN" "$C_END"
echo

say "… جلب قائمة مستودعاتك من GitHub"
REMOTE_OK=""
declare -A CANON=()
# بلا $(...) حتى تبقى REMOTE_LIST_NOTE في هذه الـ shell
if list_remote_repos >"$WORK/remote" && [ -s "$WORK/remote" ]; then
	REMOTE_OK=1
	while IFS= read -r n; do [ -n "$n" ] && CANON[${n,,}]=$n; done <"$WORK/remote"
	[ -n "$REMOTE_LIST_NOTE" ] && say "($REMOTE_LIST_NOTE)"
else
	say "تعذّر جلب القائمة — سيُكتفى بالمجلدات المربوطة بـ GitHub (استعمل --list ملف أو gh auth login)."
fi

# المجلدات العادية تُطابَق بالاسم فقط في وضع المطابقة
names_to_match=()
[ "$MODE" = mirror ] && [ -n "$REMOTE_OK" ] && names_to_match=("${CANON[@]}")

declare -A SEEN_DIR=() FOUND=() REPO_DIR=()
REPOS=()
CANDS=()
while IFS= read -r -d '' path; do
	if [ "${path##*/}" != .git ]; then
		CANDS+=("$path")
		continue
	fi
	dir=${path%/.git}
	[ -n "${SEEN_DIR[$dir]:-}" ] && continue
	SEEN_DIR[$dir]=1
	if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>"$ERRF"; then
		if grep -q 'dubious ownership' "$ERRF"; then
			report ERR "$(basename "$dir")" "$dir" "git يرفض هذا المجلد (dubious ownership) — الحل: git config --global --add safe.directory \"$dir\""
		fi
		continue
	fi
	# الرابط كما هو محفوظ (git remote -v يعرضه بعد تطبيق قواعد insteadOf)
	remotes=$(git -C "$dir" config --local --get-regexp '^remote\..*\.url$' 2>/dev/null) || continue
	while read -r key url; do
		rname=${key#remote.}
		rname=${rname%.url}
		name=$(repo_from_url "$url") || continue
		REPO_DIR[$dir]=1
		in_only "$name" || break
		FOUND[${name,,}]=1
		REPOS+=("$dir"$'\t'"$rname"$'\t'"$name")
		break
	done <<<"$remotes"
done < <(find_dirs "${names_to_match[@]}")

echo
if [ ${#REPOS[@]} -eq 0 ]; then
	say "لم يُعثر على أي مجلد مربوط بمستودعات $OWNER."
else
	printf '%sوُجد %d مجلد مربوط بـ GitHub:%s\n' "$C_HEAD" "${#REPOS[@]}" "$C_END"
	for entry in "${REPOS[@]}"; do
		IFS=$'\t' read -r dir rname name <<<"$entry"
		sync_repo "$dir" "$rname" "$name"
	done
fi

header_shown=""
for dir in "${CANDS[@]}"; do
	[ -n "${REPO_DIR[$dir]:-}" ] && continue
	# مجلد فرعي داخل مشروع آخر: ليس نسخة من المستودع
	if [ ! -e "$dir/.git" ] && git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		continue
	fi
	base=${dir##*/}
	name=${CANON[${base,,}]:-}
	{ [ -n "$name" ] && in_only "$name"; } || continue
	if [ -z "$header_shown" ]; then
		echo
		printf '%sمجلدات تحمل اسم مستودع وغير مربوطة بـ GitHub:%s\n' "$C_HEAD" "$C_END"
		header_shown=1
	fi
	FOUND[${name,,}]=1
	adopt_dir "$dir" "$name"
done

if [ -n "$REMOTE_OK" ]; then
	echo
	printf '%sمستودعاتك على GitHub غير الموجودة على الجهاز:%s\n' "$C_HEAD" "$C_END"
	missing=0
	for key in "${!CANON[@]}"; do
		name=${CANON[$key]}
		in_only "$name" || continue
		[ -n "${FOUND[$key]:-}" ] && continue
		missing=$((missing + 1))
		if [ "$CLONE_MISSING" = 1 ]; then
			clone_repo "$name"
		else
			report MISS "$name" "" "غير موجود على الجهاز (--clone-missing يستنسخه إلى $(disp "$CLONE_DIR"))"
		fi
	done
	[ "$missing" = 0 ] && say "لا شيء — كل المستودعات موجودة."
fi

# ─── الملخّص ───────────────────────────────────────────────────────────────
declare -A COUNT=()
for r in "${RESULTS[@]}"; do
	k=${r%%$'\t'*}
	COUNT[$k]=$(( ${COUNT[$k]:-0} + 1 ))
done
echo
printf '%sالملخّص%s' "$C_HEAD" "$C_END"
[ "$DRY_RUN" = 1 ] && printf ' (معاينة)'
echo
if [ "$DRY_RUN" = 1 ]; then
	upd_label="سيُطابَق" link_label="سيُربط" new_label="سيُستنسخ"
elif [ "$MODE" = safe ]; then
	upd_label="حُدّث" link_label="رُبط" new_label="استُنسخ"
else
	upd_label="طوبق" link_label="رُبط" new_label="استُنسخ"
fi
printf '  %s%s: %d · %s: %d · %s: %d%s · مطابق مسبقًا: %d · تُخطّي: %d · غير موجود محليًا: %d · أخطاء: %d\n' \
	"$C_OK" "$upd_label" "${COUNT[UPD]:-0}" "$link_label" "${COUNT[LINK]:-0}" "$new_label" "${COUNT[NEW]:-0}" "$C_END" \
	"${COUNT[OK]:-0}" "${COUNT[SKIP]:-0}" "${COUNT[MISS]:-0}" "${COUNT[ERR]:-0}"
if [ $(( ${COUNT[SKIP]:-0} + ${COUNT[ERR]:-0} )) -gt 0 ]; then
	echo "  يحتاج انتباهك:"
	for r in "${RESULTS[@]}"; do
		IFS=$'\t' read -r k name msg <<<"$r"
		case $k in SKIP|ERR) printf '   - [%s] %s: %s\n' "$k" "$name" "$msg" ;; esac
	done
fi
if [ -n "$ANY_STASH$ANY_BACKUP" ]; then
	echo "  للاسترجاع (من داخل مجلد المشروع):"
	[ -n "$ANY_STASH" ] && echo "   - تعديلاتك المحلية:      git stash list   ثم   git stash pop"
	[ -n "$ANY_BACKUP" ] && echo "   - الـ commits المحفوظة:  git branch --list \"sync-backup/*\"   ثم   git merge <اسم الفرع>"
fi

[ "${COUNT[ERR]:-0}" -eq 0 ]
