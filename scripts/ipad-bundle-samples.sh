#!/bin/sh
# Optional local development fixtures. Never fetch or publish private photographs.
set -eu
sample_source="${PHOTONS_IPAD_SAMPLE_DIR:-$SRCROOT/../../local/ipad-samples}"
sample_destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/BostonSamples"
mkdir -p "$sample_destination"
# Remove stale bundled copies if samples were disabled or changed for this build.
for photo in "$sample_destination"/*.3FR; do
    [ -f "$photo" ] || continue
    rm "$photo"
done
sample_default=NO
[ "${CONFIGURATION:-Debug}" != Debug ] || sample_default=YES
if [ "${PHOTONS_INCLUDE_BOSTON_SAMPLES:-$sample_default}" = YES ] && [ -d "$sample_source" ]; then
    for number in 659 660 661 662; do
        photo="$sample_source/B0000$number.3FR"
        [ -f "$photo" ] || { echo "error: Missing Boston sample $photo"; exit 1; }
        cp -p "$photo" "$sample_destination/"
    done
fi
