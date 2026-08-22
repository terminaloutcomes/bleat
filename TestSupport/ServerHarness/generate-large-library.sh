#!/bin/zsh
# Generates a large synthetic audiobook library for the 10,000-book
# performance baseline (GitHub issue #46, spec section 19).
#
# Each book is one folder containing a ~1s silent mp3 plus a metadata.json.
# The audio content is irrelevant to the performance baseline; only the
# record count and metadata variety matter, so a single silent mp3 is
# generated once and copied into every book folder.
#
# Usage:
#   BLEAT_LARGE_LIBRARY_COUNT=10000 \
#     TestSupport/ServerHarness/generate-large-library.sh [output-dir]
#
# Defaults: count from BLEAT_LARGE_LIBRARY_COUNT (or 10000), output dir is
# TestSupport/ServerHarness/media-large relative to the repo root.

set -euo pipefail

bleat_repository_root="${BLEAT_REPOSITORY_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
count="${BLEAT_LARGE_LIBRARY_COUNT:-10000}"
output_dir="${1:-${bleat_repository_root}/TestSupport/ServerHarness/media-large}"

if ! command -v ffmpeg >/dev/null 2>&1; then
    print -u2 "ffmpeg is required to generate the large library"
    exit 64
fi

print "Generating ${count} synthetic books under ${output_dir}"

mkdir -p "${output_dir}"

# Reconcile the directory to exactly the requested count by removing any
# book folders left over from a previous run with a higher count. Without
# this, generating 100 books after a 10,000-book run would leave 9,900
# stale folders and the seed scan could never match the expected total.
# A local nullglob ensures the glob expands to nothing when there are no
# matches, so rm does not error under set -e.
setopt local_options NULL_GLOB
rm -rf "${output_dir}/book-"*

# Generate one silent mp3 once. ~1s, 32kbps, mono — a few KB.
silent_mp3="${output_dir}/.silent-template.mp3"
if [[ ! -f "${silent_mp3}" ]]; then
    ffmpeg -y -hide_banner -loglevel error \
        -f lavfi -i anullsrc=channel_layout=mono:sample_rate=16000 \
        -t 1 -b:a 32k "${silent_mp3}"
fi

author_pool=(
    "Author One" "Author Two" "Author Three" "Author Four"
    "Co-Author Alpha" "Co-Author Beta" "Writer One" "Writer Two"
    "Historian" "Poet" "Scientist" "Explorer" "Philosopher"
    "Novelist" "Critic" "Dreamer" "Traveler" "Archivist"
)
genre_pool=(
    "Fiction" "Non-Fiction" "Science Fiction" "Fantasy"
    "Mystery" "Biography" "History" "Romance" "Thriller"
    "Adventure" "Horror" "Drama" "Comedy"
)
years=("1950" "1970" "1990" "2010" "2020")

start_seconds=$(date +%s)
for index in {0..$((count - 1))}; do
    book_dir="${output_dir}/book-$(printf '%05d' "${index}")"
    mkdir -p "${book_dir}"
    cp "${silent_mp3}" "${book_dir}/track.mp3"

    author_name="${author_pool[$((index % ${#author_pool} + 1))]}"
    series_index=$((index % 12))
    if (( series_index > 0 )); then
        series_name="Series ${series_index}"
        series_block="[{\"name\":\"${series_name}\",\"sequence\":\"$((index % 20))\"}]"
    else
        series_block="[]"
    fi
    genre_count=$(( (index % 3) + 1 ))
    genres="["
    for gi in {1..${genre_count}}; do
        (( gi > 1 )) && genres+=","
        genres+="\"${genre_pool[$(((index + gi) % ${#genre_pool} + 1))]}\""
    done
    genres+="]"
    year="${years[$((index % ${#years} + 1))]}"
    publisher=""
    if (( index % 2 == 0 )); then
        publisher="\"publisher\":\"Publisher $((index % 6))\","
    fi
    explicit="false"
    if (( index % 10 == 0 )); then
        explicit="true"
    fi

    cat >"${book_dir}/metadata.json" <<EOF
{
  "metadata": {
    "title": "Book Title ${index}",
    "authors": ["${author_name}"],
    "narrators": ["Narrator $((index % 7))"],
    "genres": ${genres},
    "series": ${series_block},
    "year": "${year}",
    ${publisher}
    "explicit": ${explicit}
  },
  "tags": ["tag-$((index % 9))"]
}
EOF
done

# Remove the template so Audiobookshelf does not treat it as a book.
rm -f "${silent_mp3}"

elapsed=$(( $(date +%s) - start_seconds ))
print "Generated ${count} books in ${elapsed}s under ${output_dir}"
