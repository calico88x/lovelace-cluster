#!/bin/sh
set -eu

export GIT_SSH_COMMAND="ssh \
  -i /ssh/id_ed25519 \
  -o IdentitiesOnly=yes \
  -o UserKnownHostsFile=/ssh/known_hosts \
  -o StrictHostKeyChecking=yes"

ROOT="/library"
REPO="${ROOT}/repo"
RELEASES="${ROOT}/releases"
CURRENT="${ROOT}/current"
LOCK_FILE="${ROOT}/.radio-library-sync.lock"

#
# Serialize all access to the persistent Git checkout and release tree.
#
exec 9>"${LOCK_FILE}"

if ! flock -n 9; then
  echo "Radio library reconciliation already in progress; exiting."
  exit 0
fi

echo "Acquired radio library reconciliation lock."

#
# Validate the persistent Git checkout.
#
if ! git -C "${REPO}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: ${REPO} is not a valid Git checkout"
  exit 1
fi

mkdir -p "${RELEASES}"

#
# Fetch desired state from Forgejo.
#
git -C "${REPO}" fetch --prune origin main

TARGET_COMMIT="$(git -C "${REPO}" rev-parse origin/main)"
TARGET_RELEASE="${RELEASES}/${TARGET_COMMIT}"

#
# Record the currently published release.
#
CURRENT_TARGET=""

if [ -L "${CURRENT}" ]; then
  CURRENT_TARGET="$(readlink "${CURRENT}")"
fi

#
# Fast path: nothing changed.
#
if [ "${CURRENT_TARGET}" = "releases/${TARGET_COMMIT}" ] \
  && [ -d "${TARGET_RELEASE}/music" ]; then
  echo "Library already current at ${TARGET_COMMIT}"
  exit 0
fi

echo "Preparing library commit ${TARGET_COMMIT}"

#
# Reconcile the persistent repository.
#
GIT_LFS_SKIP_SMUDGE=1 \
  git -C "${REPO}" reset --hard "${TARGET_COMMIT}"

cd "${REPO}"
git lfs pull
git lfs fsck
cd /

#
# Prepare a complete release before publishing it.
#
TMP_RELEASE="${RELEASES}/.${TARGET_COMMIT}.tmp"

rm -rf "${TMP_RELEASE}"
mkdir -p "${TMP_RELEASE}"

cp -a "${REPO}/music" "${TMP_RELEASE}/music"

if [ -d "${REPO}/idents" ]; then
  cp -a "${REPO}/idents" "${TMP_RELEASE}/idents"
fi

if [ -d "${REPO}/specials" ]; then
  cp -a "${REPO}/specials" "${TMP_RELEASE}/specials"
fi

#
# Validate the release.
#
TRACKED_COUNT="$(
  git -C "${REPO}" ls-files 'music/*' |
  wc -l |
  tr -d ' '
)"

RELEASE_COUNT="$(
  find "${TMP_RELEASE}/music" -type f |
  wc -l |
  tr -d ' '
)"

echo "Tracked music files:   ${TRACKED_COUNT}"
echo "Published music files: ${RELEASE_COUNT}"

if [ "${TRACKED_COUNT}" -eq 0 ] \
  || [ "${TRACKED_COUNT}" -ne "${RELEASE_COUNT}" ]; then
  echo "ERROR: release validation failed"
  exit 1
fi

#
# Convert the validated temporary tree into an immutable release.
#
if [ ! -d "${TARGET_RELEASE}" ]; then
  mv "${TMP_RELEASE}" "${TARGET_RELEASE}"
else
  rm -rf "${TMP_RELEASE}"
fi

#
# current must remain a symlink controlled by this reconciler.
#
if [ -e "${CURRENT}" ] && [ ! -L "${CURRENT}" ]; then
  echo "ERROR: ${CURRENT} exists and is not a symlink"
  exit 1
fi

NEXT_LINK="${ROOT}/.current.${TARGET_COMMIT}"

rm -f "${NEXT_LINK}"
ln -s "releases/${TARGET_COMMIT}" "${NEXT_LINK}"

#
# Atomic publication.
#
mv -Tf "${NEXT_LINK}" "${CURRENT}"

#
# Keep current plus one previous release.
#
PREVIOUS_RELEASE=""

case "${CURRENT_TARGET}" in
  releases/*)
    PREVIOUS_RELEASE="${ROOT}/${CURRENT_TARGET}"
    ;;
esac

for RELEASE in "${RELEASES}"/*; do
  [ -d "${RELEASE}" ] || continue

  if [ "${RELEASE}" = "${TARGET_RELEASE}" ]; then
    continue
  fi

  if [ -n "${PREVIOUS_RELEASE}" ] \
    && [ "${RELEASE}" = "${PREVIOUS_RELEASE}" ]; then
    continue
  fi

  echo "Pruning old release: ${RELEASE}"
  rm -rf -- "${RELEASE}"
done

#
# Remove LFS objects no longer needed by the repository.
#
cd "${REPO}"
git lfs prune
cd /

echo "Published radio library:"
echo "${TARGET_COMMIT}"
echo "Current -> $(readlink "${CURRENT}")"