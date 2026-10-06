#!/usr/bin/env bash
# Refuses to continue unless tag $1 is (a) an annotated tag, (b) signed by a
# key in the maintainer allow-list, and (c) points at a commit on main
# (releases are cut from CI on a signed tag).
#
#   .github/scripts/verify_release_tag.sh <tag> <allowed_signers file>
#
# The allow-list is passed in, not read from the tagged tree: publish.yaml
# extracts it from origin/main so a tag can never vouch for itself.
set -euo pipefail

tag="${1:?usage: $0 <tag> <allowed_signers>}"
allowed="${2:?usage: $0 <tag> <allowed_signers>}"

if ! grep -qvE '^[[:space:]]*(#|$)' "$allowed"; then
  echo "::error file=.github/allowed_signers::no maintainer signing keys are listed on main; add one (see the file's header) before releasing."
  exit 1
fi

if [[ "$(git cat-file -t "refs/tags/$tag")" != "tag" ]]; then
  echo "::error::$tag is a lightweight tag. Release tags must be annotated and signed: git tag -s $tag"
  exit 1
fi

# git picks the verifier from the signature type; only SSH signatures are
# accepted here because only SSH keys are trusted (allowed_signers).
if ! git -c gpg.format=ssh -c "gpg.ssh.allowedSignersFile=$allowed" \
  verify-tag "$tag"; then
  echo "::error::$tag is not signed by a key listed in .github/allowed_signers on main."
  exit 1
fi

commit="$(git rev-parse "refs/tags/$tag^{commit}")"
if ! git merge-base --is-ancestor "$commit" refs/remotes/origin/main; then
  echo "::error::$tag points at $commit, which is not on main. Release from main only."
  exit 1
fi

echo "OK: $tag is signed by an allowed maintainer key and is on main ($commit)."
