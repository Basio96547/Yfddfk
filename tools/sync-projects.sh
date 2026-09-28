#!/usr/bin/env bash
# sync-projects.sh — يحدّث كل نسخة محلية من مشاريعك إلى آخر تحديث على GitHub، كلٌّ في مكانه.
#
# يبحث في الجهاز عن كل مجلد git مربوط بمستودع لصاحب الحساب على GitHub، فيجلب آخر
# تحديث ويطبّقه في نفس المجلد، ثم يذكر مستودعاتك غير الموجودة على الجهاز.
# صُمّم لـ Git Bash على Windows، ويعمل كذلك على Linux وmacOS (bash 4.4+).
#
# الاستخدام:
#   bash sync-projects.sh --dry-run     معاينة ما سيحدث لكل مشروع بلا أي تعديل
#   bash sync-projects.sh               تحديث آمن
#
# الوضع الافتراضي آمن: تحديث fast-forward فقط؛ لا يمسّ تعديلًا محليًا غير محفوظ
# ولا commit غير مرفوع، والمشروع الذي لا يُحدَّث بأمان يُتخطّى مع ذكر السبب.
# المجلد الذي انتهى فرعه (كل commits الفرع موجودة في الفرع الافتراضي على GitHub)
# يُنقل إلى الفرع الافتراضي، ويبقى الفرع القديم محليًا كما هو.
#
# الخيارات:
#   --dry-run          اعرض الخطة فقط (يجلب من GitHub لكنه لا يغيّر ملفاتك).
#   --force            حدّث حتى المشاريع المتعارضة: التعديلات المحلية تُحفظ في git stash
#                      والـ commits غير المرفوعة في فرع sync-backup/... ثم تُطابَق مع GitHub.
#                      يُفضّل استعماله مع --only.
#   --only a,b         اقصر العمل على هذه المستودعات (بأسمائها على GitHub).
#   --clone-missing    استنسخ مستودعاتك غير الموجودة على الجهاز إلى --clone-dir.
#   --clone-dir DIR    مكان الاستنساخ (الافتراضي: ~/Desktop/GitHub).
#   --deps             ثبّت الحزم (npm/pnpm/yarn/bun) حيث تغيّرت الاعتماديات أو استُنسخ المشروع.
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

OWNER=Basio96547
DRY_RUN=0
FORCE=0
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
		--force) FORCE=1 ;;
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
ERRF=$(mktemp)
trap 'rm -f "$ERRF"' EXIT

if [ -t 1 ]; then
	C_OK=$'\e[32m' C_WARN=$'\e[33m' C_ERR=$'\e[31m' C_DIM=$'\e[2m' C_HEAD=$'\e[1;36m' C_END=$'\e[0m'
else
	C_OK="" C_WARN="" C_ERR="" C_DIM="" C_HEAD="" C_END=""
fi

disp() {
	if [ -n "$IS_WINDOWS" ] && command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}

say() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_END"; }

# OK: محدّث مسبقًا · UPD: حُدّث · NEW: استُنسخ · SKIP: تُخطّي · MISS: غير موجود محليًا · ERR: خطأ
RESULTS=()
report() {
	local kind=$1 name=$2 dir=$3 msg=$4 color=$C_DIM
	case $kind in
		UPD|NEW) color=$C_OK ;;
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

find_git_dirs() {
	local -a prune=(-name '.*')
	local n root
	for n in "${PRUNE_NAMES[@]}"; do prune+=(-o -name "$n"); done
	for root in "${ROOTS[@]}"; do
		[ -d "$root" ] || continue
		say "… البحث في $(disp "$root")" >&2
		find "$root" -mindepth 1 -maxdepth "$DEPTH" -type d \
			\( \( -name .git -print0 -prune \) -o \( \( "${prune[@]}" \) -prune \) \) 2>/dev/null
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

# يحفظ كل تعديل محلي (مع الملفات غير المتتبَّعة، دون المتجاهَلة مثل .env وnode_modules)
stash_local() {
	local dir=$1
	[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ] || return 0
	git -C "$dir" stash push --include-untracked -q -m "sync-projects $TS" 2>"$ERRF" || return 1
	stashed=1
}

backup_branch() {
	local dir=$1 rev=$2 label=$3
	backup="sync-backup/$TS/$label"
	git -C "$dir" branch -q "$backup" "$rev" 2>"$ERRF"
}

finish_update() {
	local dir=$1 name=$2 old=$3 branch=$4 new count
	new=$(git -C "$dir" rev-parse HEAD)
	count=$(git -C "$dir" rev-list --count "$old..$new" 2>/dev/null || echo 0)
	msg="حُدّث ($branch): $count commit جديد — آخرها: $(git -C "$dir" log -1 --date=short --format='%s (%cd)')"
	if [ -f "$dir/.gitmodules" ]; then
		git -C "$dir" submodule update --init --recursive --quiet 2>"$ERRF" || msg+=" | تعذّر تحديث submodules: $(last_err)"
	fi
	[ -n "$stashed" ] && msg+=" | التعديلات المحلية حُفظت في stash باسم \"sync-projects $TS\" (استرجاعها: git stash pop)"
	[ -n "$backup" ] && msg+=" | الـ commits المحلية محفوظة في الفرع $backup"
	deps_after_update "$dir" "$old" "$new"
	[ -n "$hint" ] && msg+=" | $hint"
	report UPD "$name" "$dir" "$msg"
}

sync_repo() {
	local dir=$1 remote=$2 name=$3
	local -a g=(git -C "$dir")
	local gd def branch up target="" switch="" dirty="" old ahead behind hint msg="" stashed="" backup=""

	gd=$("${g[@]}" rev-parse --absolute-git-dir 2>"$ERRF") || { report ERR "$name" "$dir" "$(last_err)"; return; }
	if [ -e "$gd/MERGE_HEAD" ] || [ -e "$gd/CHERRY_PICK_HEAD" ] || [ -e "$gd/REVERT_HEAD" ] ||
		[ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]; then
		report SKIP "$name" "$dir" "فيه عملية merge/rebase لم تكتمل — أكملها أو ألغِها أولًا"
		return
	fi
	if ! "${g[@]}" fetch --prune --quiet "$remote" 2>"$ERRF"; then
		report ERR "$name" "$dir" "فشل الجلب من GitHub: $(last_err)"
		return
	fi
	if ! has_ref "$dir" HEAD; then
		report SKIP "$name" "$dir" "المستودع المحلي بلا أي commit — انقل المجلد جانبًا ثم أعد التشغيل مع --clone-missing"
		return
	fi

	# الفرع الافتراضي كما هو الآن على GitHub
	"${g[@]}" remote set-head "$remote" --auto >/dev/null 2>&1
	def=$("${g[@]}" symbolic-ref -q --short "refs/remotes/$remote/HEAD" 2>/dev/null) || def=""
	def=${def#"$remote"/}
	[ -n "$def" ] && ! has_ref "$dir" "refs/remotes/$remote/$def" && def=""

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
		local from=${branch:-"HEAD منفصل"} contained="" w_ok=1 reasons=""
		is_anc "$dir" HEAD "$target" && contained=1
		has_ref "$dir" "refs/heads/$switch" && ! is_anc "$dir" "refs/heads/$switch" "$target" && w_ok=""

		if [ -z "$contained" ] || [ -n "$dirty" ] || [ -z "$w_ok" ]; then
			[ -n "$dirty" ] && reasons+="تعديلات محلية غير محفوظة؛ "
			[ -z "$contained" ] && reasons+="$from فيه commits غير موجودة في $def على GitHub؛ "
			[ -z "$w_ok" ] && reasons+="فرع $switch المحلي فيه commits غير مرفوعة؛ "
			if [ "$FORCE" = 0 ]; then
				report SKIP "$name" "$dir" "${reasons%؛ } — لم يُلمس (--force ينقله إلى $def بعد حفظ نسخة احتياطية)"
				return
			fi
		fi
		if [ "$DRY_RUN" = 1 ]; then
			msg="سينتقل من $from إلى $def ويحدّثه"
			[ -n "$reasons" ] && msg+=" (مع --force: ${reasons%؛ } تُحفظ أولًا)"
			[ -n "$hint" ] && msg+=" | $hint"
			report UPD "$name" "$dir" "$msg"
			return
		fi
		if [ -n "$reasons" ]; then
			stash_local "$dir" || { report ERR "$name" "$dir" "تعذّر حفظ التعديلات المحلية: $(last_err)"; return; }
			if [ -z "$branch" ] && [ -z "$contained" ]; then
				backup_branch "$dir" HEAD detached || { report ERR "$name" "$dir" "$(last_err)"; return; }
			fi
			if [ -z "$w_ok" ]; then
				backup_branch "$dir" "refs/heads/$switch" "$switch" || { report ERR "$name" "$dir" "$(last_err)"; return; }
			fi
		fi
		if ! "${g[@]}" checkout -q -B "$switch" --track "$target" 2>"$ERRF"; then
			if [ "$FORCE" = 1 ] && stash_local "$dir" && "${g[@]}" checkout -q -B "$switch" --track "$target" 2>"$ERRF"; then
				:
			else
				report SKIP "$name" "$dir" "تعذّر الانتقال إلى $def: $(last_err)"
				return
			fi
		fi
		finish_update "$dir" "$name" "$old" "$switch"
		[ -n "$branch" ] && say "        (الفرع $branch ما زال محليًا كما هو)"
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

	if [ "$ahead" -gt 0 ] && [ "$FORCE" = 0 ]; then
		report SKIP "$name" "$dir" "تباعد: $ahead commit محلي غير مرفوع و$behind جديد على GitHub — لم يُلمس (git pull --rebase يدويًا، أو --force)"
		return
	fi

	if [ "$DRY_RUN" = 1 ]; then
		msg="سيُحدَّث ($branch): $behind commit جديد"
		[ "$ahead" -gt 0 ] && msg+=" (مع --force: $ahead commit محلي يُحفظ في فرع احتياطي ثم يُطابَق GitHub)"
		[ -n "$dirty" ] && msg+=" — فيه تعديلات محلية؛ إن تعارضت مع التحديث فسيُتخطّى (أو يحفظها --force في stash)"
		[ -n "$hint" ] && msg+=" | $hint"
		report UPD "$name" "$dir" "$msg"
		return
	fi

	if [ "$ahead" -gt 0 ]; then
		backup_branch "$dir" HEAD "$branch" || { report ERR "$name" "$dir" "$(last_err)"; return; }
		stash_local "$dir" || { report ERR "$name" "$dir" "تعذّر حفظ التعديلات المحلية: $(last_err)"; return; }
		"${g[@]}" reset -q --hard "$target" 2>"$ERRF" || { report ERR "$name" "$dir" "$(last_err)"; return; }
	elif ! "${g[@]}" merge -q --ff-only "$target" 2>"$ERRF"; then
		# git يسرد الملفات المتعارضة في أسطر تبدأ بمسافة
		local files; files=$(grep -E '^[[:space:]]+[^[:space:]]' "$ERRF" | sed -E 's/^[[:space:]]+//' | head -n 5 | paste -sd ',' - | sed 's/,/، /g')
		[ -z "$files" ] && files=$(last_err)
		if [ "$FORCE" = 1 ] && stash_local "$dir" && "${g[@]}" merge -q --ff-only "$target" 2>"$ERRF"; then
			:
		else
			report SKIP "$name" "$dir" "تعديلات محلية تتعارض مع التحديث ($files) — احفظها (commit أو stash) أو استعمل --force"
			return
		fi
	fi
	finish_update "$dir" "$name" "$old" "$branch"
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
	msg="استُنسخ ($(git -C "$dest" symbolic-ref -q --short HEAD 2>/dev/null)) — آخر commit: $(git -C "$dest" log -1 --date=short --format='%s (%cd)' 2>/dev/null)"
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
	local token page=1 out names
	local -a auth=()
	# رمز الدخول الذي يحفظه Git Credential Manager لـ github.com (لا يُطبع ولا يُحفظ)
	token=$(printf 'protocol=https\nhost=github.com\n\n' | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null | sed -n 's/^password=//p')
	if [ -n "$token" ]; then
		auth=(-H "Authorization: Bearer $token")
	else
		REMOTE_LIST_NOTE="بلا تسجيل دخول: القائمة تشمل المستودعات العامة فقط"
	fi
	while :; do
		if [ -n "$token" ]; then
			out=$(curl -fsSL "${auth[@]}" "https://api.github.com/user/repos?per_page=100&page=$page&affiliation=owner") || return 1
		else
			out=$(curl -fsSL "https://api.github.com/users/$OWNER/repos?per_page=100&page=$page") || return 1
		fi
		names=$(printf '%s' "$out" | grep -o '"full_name": *"[^"]*"' | sed -E 's/.*"([^"]*)"$/\1/')
		[ -z "$names" ] && break
		printf '%s\n' "$names" | grep -i "^$OWNER/" | sed 's#.*/##'
		page=$((page + 1))
	done
}

# ─── التنفيذ ───────────────────────────────────────────────────────────────
printf '%sمزامنة مشاريع %s مع GitHub%s' "$C_HEAD" "$OWNER" "$C_END"
[ "$DRY_RUN" = 1 ] && printf ' %s(معاينة فقط — لن يتغيّر شيء)%s' "$C_WARN" "$C_END"
[ "$FORCE" = 1 ] && printf ' %s(--force)%s' "$C_WARN" "$C_END"
echo

declare -A SEEN_DIR=() FOUND=()
REPOS=()
while IFS= read -r -d '' gitdir; do
	dir=${gitdir%/.git}
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
		in_only "$name" || break
		FOUND[${name,,}]=1
		REPOS+=("$dir"$'\t'"$rname"$'\t'"$name")
		break
	done <<<"$remotes"
done < <(find_git_dirs)

echo
if [ ${#REPOS[@]} -eq 0 ]; then
	say "لم يُعثر على أي نسخة محلية من مستودعات $OWNER."
else
	printf '%sوُجدت %d نسخة محلية:%s\n' "$C_HEAD" "${#REPOS[@]}" "$C_END"
	for entry in "${REPOS[@]}"; do
		IFS=$'\t' read -r dir rname name <<<"$entry"
		sync_repo "$dir" "$rname" "$name"
	done
fi

echo
printf '%sمستودعاتك على GitHub غير الموجودة على الجهاز:%s\n' "$C_HEAD" "$C_END"
if remote_names=$(list_remote_repos) && [ -n "$remote_names" ]; then
	[ -n "$REMOTE_LIST_NOTE" ] && say "($REMOTE_LIST_NOTE)"
	missing=0
	while IFS= read -r name; do
		{ [ -n "$name" ] && in_only "$name"; } || continue
		[ -n "${FOUND[${name,,}]:-}" ] && continue
		missing=$((missing + 1))
		if [ "$CLONE_MISSING" = 1 ]; then
			clone_repo "$name"
		else
			report MISS "$name" "" "غير موجود على الجهاز (--clone-missing يستنسخه إلى $(disp "$CLONE_DIR"))"
		fi
	done <<<"$remote_names"
	[ "$missing" = 0 ] && say "لا شيء — كل المستودعات موجودة."
else
	say "تعذّر جلب قائمة مستودعاتك من GitHub (استعمل --list ملف أو سجّل الدخول بـ gh auth login)."
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
[ "$DRY_RUN" = 1 ] && upd_label="سيُحدَّث" || upd_label="حُدّث"
[ "$DRY_RUN" = 1 ] && new_label="سيُستنسخ" || new_label="استُنسخ"
printf '  %s%s: %d%s · محدّث مسبقًا: %d · %s: %d · تُخطّي: %d · غير موجود محليًا: %d · أخطاء: %d\n' \
	"$C_OK" "$upd_label" "${COUNT[UPD]:-0}" "$C_END" "${COUNT[OK]:-0}" "$new_label" "${COUNT[NEW]:-0}" \
	"${COUNT[SKIP]:-0}" "${COUNT[MISS]:-0}" "${COUNT[ERR]:-0}"
if [ $(( ${COUNT[SKIP]:-0} + ${COUNT[ERR]:-0} )) -gt 0 ]; then
	echo "  يحتاج انتباهك:"
	for r in "${RESULTS[@]}"; do
		IFS=$'\t' read -r k name msg <<<"$r"
		case $k in SKIP|ERR) printf '   - [%s] %s: %s\n' "$k" "$name" "$msg" ;; esac
	done
fi

[ "${COUNT[ERR]:-0}" -eq 0 ]
