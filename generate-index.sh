#!/bin/bash
# Robust index generator for blog posts using jq

OUTPUT_FILE="index.json"
echo "[]" > "$OUTPUT_FILE"

# Get files sorted by date in frontmatter (newest first)
files=$(grep -l "^date:" *.md | xargs grep -H "^date:" | sed 's/:\s*date:\s*/ /' | sort -k2r | cut -d' ' -f1)

for f in $files; do
  if [ "$f" = "README.md" ]; then continue; fi

  # Extract metadata
  title=$(grep "^title:" "$f" | head -1 | cut -d':' -f2- | sed 's/^[ "]*//;s/[ "]*$//')
  date=$(grep "^date:" "$f" | head -1 | cut -d':' -f2- | sed 's/^[ "]*//;s/[ "]*$//')
  desc=$(grep "^description:" "$f" | head -1 | cut -d':' -f2- | sed 's/^[ "]*//;s/[ "]*$//')
  tags=$(grep "^tags:" "$f" | head -1 | cut -d':' -f2- | sed 's/^[ ]*//')

  # Validation: Ensure mandatory fields exist
  if [[ -z "$title" || -z "$date" ]]; then
    echo "Error: Mandatory metadata (title/date) missing in $f. Skipping." >&2
    continue
  fi

  # Calculate Reading Time (assuming 200 words per minute)
  # Exclude frontmatter from word count
  wordCount=$(sed '1,/^---/d; /^---/,$d' "$f" | wc -w)
  readingTime=$(( (wordCount / 200) + 1 ))

  # Get last updated date from Git
  lastGitDate=$(git log -1 --format=%cs -- "$f" 2>/dev/null)
  lastUpdated="${lastGitDate:-$date}"

  # Use jq to append a new object to the array
  jq --arg slug "${f%.md}" \
     --arg title "$title" \
     --arg date "$date" \
     --arg lastUpdated "$lastUpdated" \
     --arg desc "$desc" \
     --arg filePath "$f" \
     --argjson tags "${tags:-[]}" \
     --argjson readingTime "$readingTime" \
     '. += [{
       slug: $slug,
       title: $title,
       date: $date,
       lastUpdated: $lastUpdated,
       description: $desc,
       tags: $tags,
       readingTime: $readingTime,
       filePath: $filePath
     }]' \
     "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
done

echo "Successfully generated $OUTPUT_FILE with $(jq '. | length' $OUTPUT_FILE) posts."
