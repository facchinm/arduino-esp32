#!/bin/bash

if [ ! $GITHUB_EVENT_NAME == "release" ]; then
    echo "Wrong event '$GITHUB_EVENT_NAME'!"
    exit 1
fi

EVENT_JSON=`cat $GITHUB_EVENT_PATH`

action=`echo $EVENT_JSON | jq -r '.action'`
if [ ! $action == "published" ]; then
    echo "Wrong action '$action'. Exiting now..."
    exit 0
fi

draft=`echo $EVENT_JSON | jq -r '.release.draft'`
if [ $draft == "true" ]; then
    echo "It's a draft release. Exiting now..."
    exit 0
fi

RELEASE_PRE=`echo $EVENT_JSON | jq -r '.release.prerelease'`
RELEASE_TAG=`echo $EVENT_JSON | jq -r '.release.tag_name'`
RELEASE_BRANCH=`echo $EVENT_JSON | jq -r '.release.target_commitish'`
RELEASE_ID=`echo $EVENT_JSON | jq -r '.release.id'`
RELEASE_BODY=`echo $EVENT_JSON | jq -r '.release.body'`

OUTPUT_DIR="$GITHUB_WORKSPACE/build"
PACKAGE_NAME="esp32-$RELEASE_TAG"
PACKAGE_JSON_MERGE="$GITHUB_WORKSPACE/.github/scripts/merge_packages.py"
PACKAGE_JSON_TEMPLATE="$GITHUB_WORKSPACE/package/package_esp32_index.template.json"
PACKAGE_JSON_DEV="package_esp32_dev_index.json"
PACKAGE_JSON_REL="package_esp32_index.json"

echo "Event: $GITHUB_EVENT_NAME, Repo: $GITHUB_REPOSITORY, Path: $GITHUB_WORKSPACE, Ref: $GITHUB_REF"
echo "Action: $action, Branch: $RELEASE_BRANCH, ID: $RELEASE_ID"
echo "Tag: $RELEASE_TAG, Draft: $draft, Pre-Release: $RELEASE_PRE"

function get_file_size(){
    local file="$1"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        eval `stat -s "$file"`
        local res="$?"
        echo "$st_size"
        return $res
    else
        stat --printf="%s" "$file"
        return $?
    fi
}

function git_upload_asset(){
    local name=$(basename "$1")
    # local mime=$(file -b --mime-type "$1")
    curl -k -X POST -sH "Authorization: token $GITHUB_TOKEN" -H "Content-Type: application/octet-stream" --data-binary @"$1" "https://uploads.github.com/repos/$GITHUB_REPOSITORY/releases/$RELEASE_ID/assets?name=$name"
}

function git_safe_upload_asset(){
    local file="$1"
    local name=$(basename "$file")
    local size=`get_file_size "$file"`
    local upload_res=`git_upload_asset "$file"`
    if [ $? -ne 0 ]; then
        >&2 echo "ERROR: Failed to upload '$name' ($?)"
        return 1
    fi
    up_size=`echo "$upload_res" | jq -r '.size'`
    if [ $up_size -ne $size ]; then
        >&2 echo "ERROR: Uploaded size does not match! $up_size != $size"
        #git_delete_asset
        return 1
    fi
    echo "$upload_res" | jq -r '.browser_download_url'
    return $?
}

function git_upload_to_pages(){
    local path=$1
    local src=$2

    if [ ! -f "$src" ]; then
        >&2 echo "Input is not a file! Aborting..."
        return 1
    fi

    local info=`curl -s -k -H "Authorization: token $GITHUB_TOKEN" -H "Accept: application/vnd.github.v3.object+json" -X GET "https://api.github.com/repos/$GITHUB_REPOSITORY/contents/$path?ref=gh-pages"`
    local type=`echo "$info" | jq -r '.type'`
    local message=$(basename $path)
    local sha=""
    local content=""

    if [ $type == "file" ]; then
        sha=`echo "$info" | jq -r '.sha'`
        sha=",\"sha\":\"$sha\""
        message="Updating $message"
    elif [ ! $type == "null" ]; then
        >&2 echo "Wrong type '$type'"
        return 1
    else
        message="Creating $message"
    fi

    content=`base64 -i "$src"`
    data="{\"branch\":\"gh-pages\",\"message\":\"$message\",\"content\":\"$content\"$sha}"

    echo "$data" | curl -s -k -H "Authorization: token $GITHUB_TOKEN" -H "Accept: application/vnd.github.v3.raw+json" -X PUT --data @- "https://api.github.com/repos/$GITHUB_REPOSITORY/contents/$path"
}

function git_safe_upload_to_pages(){
    local path=$1
    local file="$2"
    local name=$(basename "$file")
    local size=`get_file_size "$file"`
    local upload_res=`git_upload_to_pages "$path" "$file"`
    if [ $? -ne 0 ]; then
        >&2 echo "ERROR: Failed to upload '$name' ($?)"
        return 1
    fi
    up_size=`echo "$upload_res" | jq -r '.content.size'`
    if [ $up_size -ne $size ]; then
        >&2 echo "ERROR: Uploaded size does not match! $up_size != $size"
        #git_delete_asset
        return 1
    fi
    echo "$upload_res" | jq -r '.content.download_url'
    return $?
}

function merge_package_json(){
    local jsonLink=$1
    local jsonOut=$2
    local old_json=$OUTPUT_DIR/oldJson.json
    local merged_json=$OUTPUT_DIR/mergedJson.json

    echo "Downloading previous JSON $jsonLink ..."
    curl -L -o "$old_json" "https://github.com/$GITHUB_REPOSITORY/releases/download/$jsonLink?access_token=$GITHUB_TOKEN" 2>/dev/null
    if [ $? -ne 0 ]; then echo "ERROR: Download Failed! $?"; exit 1; fi

    echo "Creating new JSON ..."
    set +e
    stdbuf -oL python "$PACKAGE_JSON_MERGE" "$jsonOut" "$old_json" > "$merged_json"
    set -e

    set -v
    if [ ! -s $merged_json ]; then
        rm -f "$merged_json"
        echo "Nothing to merge"
    else
        rm -f "$jsonOut"
        mv "$merged_json" "$jsonOut"
        echo "JSON data successfully merged"
    fi
    rm -f "$old_json"
    set +v
}

set -e

##
## PACKAGE ZIP
##

mkdir -p "$OUTPUT_DIR"
PKG_DIR="$OUTPUT_DIR/$PACKAGE_NAME"
PACKAGE_ZIP="$PACKAGE_NAME.zip"

echo "Updating submodules ..."
git -C "$GITHUB_WORKSPACE" submodule update --init --recursive > /dev/null 2>&1

mkdir -p "$PKG_DIR/tools"


# Run split_packages for all vendors
VENDORS=`ls vendors`
for vendor in ${VENDORS}; do

    echo "Creating package for $vendor"

    VENDOR_DIR="$OUTPUT_DIR/$PACKAGE_NAME""_$vendor"

    mkdir -p "$VENDOR_DIR/tools"

    echo "name=ESP32 Arduino (${vendor})" > ${VENDOR_DIR}/platform.txt
    cat "$GITHUB_WORKSPACE/platform.txt" | grep "version=" >> ${VENDOR_DIR}/platform.txt

    # Remove fqbns not in $FQBNS list
    touch ${VENDOR_DIR}/boards.txt
    # Save all menus (will not be displayed if unused)
    cat "$GITHUB_WORKSPACE/boards.txt" | grep "^menu\." >> ${VENDOR_DIR}/boards.txt
    BOARDS=`cat $GITHUB_WORKSPACE/vendors/$vendor`
    for board in ${BOARDS}; do
        [[ $board =~ ^#.* ]] && continue
        echo "Adding board $board"
        cat "$GITHUB_WORKSPACE/boards.txt" | grep "${board}\." >> ${VENDOR_DIR}/boards.txt
    done
    sed -i "s/build.core=esp32/build.core=esp32:esp32/g" ${VENDOR_DIR}/boards.txt

    # really, cat boards.txt for .variant and copy the right folders
    cat ${VENDOR_DIR}/boards.txt | grep "\.variant=" | cut -f2 -d"=" | xargs -I{} cp -r "$GITHUB_WORKSPACE/variants/"{} ${VENDOR_DIR}/variants/

    cp -r "$GITHUB_WORKSPACE/tools/partitions/" ${VENDOR_DIR}/tools/
    #cp -r "$GITHUB_WORKSPACE/tools/sdk/" ${VENDOR_DIR}/tools/
    cp -r $GITHUB_WORKSPACE/tools/gen* ${VENDOR_DIR}/tools/

done

# Create SDK package
# TODO: upload sdk package to download servers
pushd "$GITHUB_WORKSPACE/tools" >/dev/null
tar czvf "$OUTPUT_DIR/esp32-sdk-$RELEASE_TAG.tar.gz" sdk
popd

# Copy all core files to the package folder
echo "Copying files for packaging ..."
cp -f  "$GITHUB_WORKSPACE/boards.txt"                       "$PKG_DIR/"
cp -f  "$GITHUB_WORKSPACE/package.json"                     "$PKG_DIR/"
cp -f  "$GITHUB_WORKSPACE/programmers.txt"                  "$PKG_DIR/"
cp -Rf "$GITHUB_WORKSPACE/cores"                            "$PKG_DIR/"
cp -Rf "$GITHUB_WORKSPACE/libraries"                        "$PKG_DIR/"
cp -Rf "$GITHUB_WORKSPACE/variants"                         "$PKG_DIR/"
cp -f  "$GITHUB_WORKSPACE/tools/espota.exe"                 "$PKG_DIR/tools/"
cp -f  "$GITHUB_WORKSPACE/tools/espota.py"                  "$PKG_DIR/tools/"
cp -f  "$GITHUB_WORKSPACE/tools/gen_esp32part.py"           "$PKG_DIR/tools/"
cp -f  "$GITHUB_WORKSPACE/tools/gen_esp32part.exe"          "$PKG_DIR/tools/"
cp -f  "$GITHUB_WORKSPACE/tools/gen_insights_package.py"    "$PKG_DIR/tools/"
cp -f  "$GITHUB_WORKSPACE/tools/gen_insights_package.exe"   "$PKG_DIR/tools/"
cp -Rf "$GITHUB_WORKSPACE/tools/partitions"                 "$PKG_DIR/tools/"
cp -Rf "$GITHUB_WORKSPACE/tools/ide-debug"                  "$PKG_DIR/tools/"
#cp -Rf "$GITHUB_WORKSPACE/tools/sdk"                        "$PKG_DIR/tools/"
cp -f $GITHUB_WORKSPACE/tools/platformio-build*.py          "$PKG_DIR/tools/"

# Remove unnecessary files in the package folder
echo "Cleaning up folders ..."
find "$PKG_DIR" -name '*.DS_Store' -exec rm -f {} \;
find "$PKG_DIR" -name '*.git*' -type f -delete

# Remove non espressif boards from boards.txt and from variants/
BOARDS=`cat vendors/*`
for board in ${BOARDS}; do
    sed -i "/^${board}.*/d" "$PKG_DIR/boards.txt"
done
cat "${OUTPUT_DIR}/${PACKAGE_NAME}_"*/boards.txt | grep "\.variant=" | cut -f2 -d"=" | xargs -I{} rm -rf $PKG_DIR/variants/{}

# Replace tools locations in platform.txt
echo "Generating platform.txt..."
cat "$GITHUB_WORKSPACE/platform.txt" | \
sed "s/version=.*/version=$ver$extent/g" | \
sed 's/compiler.sdk.path={runtime.platform.path}\/tools\/sdk/compiler.sdk.path=\{runtime.tools.esp32-sdk.path\}/g' | \
sed 's/tools.xtensa-esp32-elf-gcc.path={runtime.platform.path}\/tools\/xtensa-esp32-elf/tools.xtensa-esp32-elf-gcc.path=\{runtime.tools.xtensa-esp32-elf-gcc.path\}/g' | \
sed 's/tools.xtensa-esp32s2-elf-gcc.path={runtime.platform.path}\/tools\/xtensa-esp32s2-elf/tools.xtensa-esp32s2-elf-gcc.path=\{runtime.tools.xtensa-esp32s2-elf-gcc.path\}/g' | \
sed 's/tools.xtensa-esp32s3-elf-gcc.path={runtime.platform.path}\/tools\/xtensa-esp32s3-elf/tools.xtensa-esp32s3-elf-gcc.path=\{runtime.tools.xtensa-esp32s3-elf-gcc.path\}/g' | \
sed 's/tools.riscv32-esp-elf-gcc.path={runtime.platform.path}\/tools\/riscv32-esp-elf/tools.riscv32-esp-elf-gcc.path=\{runtime.tools.riscv32-esp-elf-gcc.path\}/g' | \
sed 's/tools.esptool_py.path={runtime.platform.path}\/tools\/esptool/tools.esptool_py.path=\{runtime.tools.esptool_py.path\}/g' | \
sed 's/debug.server.openocd.path={runtime.platform.path}\/tools\/openocd-esp32\/bin\/openocd/debug.server.openocd.path=\{runtime.tools.openocd-esp32.path\}\/bin\/openocd/g' | \
sed 's/debug.server.openocd.scripts_dir={runtime.platform.path}\/tools\/openocd-esp32\/share\/openocd\/scripts\//debug.server.openocd.scripts_dir=\{runtime.tools.openocd-esp32.path\}\/share\/openocd\/scripts\//g' | \
sed 's/debug.server.openocd.scripts_dir.windows={runtime.platform.path}\\tools\\openocd-esp32\\share\\openocd\\scripts\\/debug.server.openocd.scripts_dir.windows=\{runtime.tools.openocd-esp32.path\}\\share\\openocd\\scripts\\/g' \
 > "$PKG_DIR/platform.txt"

# Add header with version information
echo "Generating core_version.h ..."
ver_define=`echo $RELEASE_TAG | tr "[:lower:].\055" "[:upper:]_"`
ver_hex=`git -C "$GITHUB_WORKSPACE" rev-parse --short=8 HEAD 2>/dev/null`
echo \#define ARDUINO_ESP32_GIT_VER 0x$ver_hex > "$PKG_DIR/cores/esp32/core_version.h"
echo \#define ARDUINO_ESP32_GIT_DESC `git -C "$GITHUB_WORKSPACE" describe --tags 2>/dev/null` >> "$PKG_DIR/cores/esp32/core_version.h"
echo \#define ARDUINO_ESP32_RELEASE_$ver_define >> "$PKG_DIR/cores/esp32/core_version.h"
echo \#define ARDUINO_ESP32_RELEASE \"$ver_define\" >> "$PKG_DIR/cores/esp32/core_version.h"

# Compress package folder
echo "Creating ZIP ..."
pushd "$OUTPUT_DIR" >/dev/null
zip -qr "$PACKAGE_ZIP" "$PACKAGE_NAME"
if [ $? -ne 0 ]; then echo "ERROR: Failed to create $PACKAGE_ZIP ($?)"; exit 1; fi

# Calculate SHA-256
echo "Calculating SHA sum ..."
PACKAGE_PATH="$OUTPUT_DIR/$PACKAGE_ZIP"
PACKAGE_SHA=`shasum -a 256 "$PACKAGE_ZIP" | cut -f 1 -d ' '`
PACKAGE_SIZE=`get_file_size "$PACKAGE_ZIP"`
popd >/dev/null
rm -rf "$PKG_DIR"
echo "'$PACKAGE_ZIP' Created! Size: $PACKAGE_SIZE, SHA-256: $PACKAGE_SHA"
echo

# Upload package to release page
echo "Uploading package to release page ..."
PACKAGE_URL=`git_safe_upload_asset "$PACKAGE_PATH"`
echo "Package Uploaded"
echo "Download URL: $PACKAGE_URL"
echo

##
## PACKAGE JSON
##

# Construct JQ argument with package data
jq_arg=".packages[0].platforms[0].version = \"$RELEASE_TAG\" | \
    .packages[0].platforms[0].url = \"$PACKAGE_URL\" |\
    .packages[0].platforms[0].archiveFileName = \"$PACKAGE_ZIP\" |\
    .packages[0].platforms[0].size = \"$PACKAGE_SIZE\" |\
    .packages[0].platforms[0].checksum = \"SHA-256:$PACKAGE_SHA\""

# Generate package JSONs
echo "Genarating $PACKAGE_JSON_DEV ..."
cat "$PACKAGE_JSON_TEMPLATE" | jq "$jq_arg" > "$OUTPUT_DIR/$PACKAGE_JSON_DEV"
if [ "$RELEASE_PRE" == "false" ]; then
    echo "Genarating $PACKAGE_JSON_REL ..."
    cat "$PACKAGE_JSON_TEMPLATE" | jq "$jq_arg" > "$OUTPUT_DIR/$PACKAGE_JSON_REL"
fi

# Generate correct version for sdk
# TODO: broken ATM
cat "$OUTPUT_DIR/$PACKAGE_JSON_DEV" | jq --arg RELEASE_TAG "$RELEASE_TAG" -r '.packages[0].tools[] | (select(.name=="esp32-sdk") |.version = $RELEASE_TAG)'

# Compress all the derived packages
# TODO: replace sed with jq
echo "Creating ZIPs for derived cores ..."
pushd "$OUTPUT_DIR" >/dev/null
CORES=`ls | grep $PACKAGE_NAME | grep -v zip | grep -v json`
for core in $CORES; do
    zip -qr $core.zip "$core"
    if [ $? -ne 0 ]; then echo "ERROR: Failed to create $core.zip ($?)"; exit 1; fi

    # Calculate SHA-256
    echo "Calculating SHA sum ..."
    _PACKAGE_PATH="$OUTPUT_DIR/$core.zip"
    _PACKAGE_SHA=`shasum -a 256 "$core.zip" | cut -f 1 -d ' '`
    _PACKAGE_SIZE=`get_file_size "$core.zip"`
    _PACKAGE_VENDOR=`echo $core | cut -f2 -d"_"`

    cat $core/boards.txt | grep "name=" | cut -f 2 -d"=" |
    while read line; do
      jq -n --arg name "$line" '{name: $name}'
    done | jq -n '.boards |= [inputs]' > _tmp_package_boards.txt

    _PACKAGE_BOARDS=`cat _tmp_package_boards.txt`
    _PACKAGE_BOARDS=`echo ${_PACKAGE_BOARDS:13:-1}`

    echo $_PACKAGE_BOARDS

    # TODO: try to create the boards names via jq

    #jq_arg=".packages[1].name = \"ESP32 $_PACKAGE_VENDOR\" | \
    #    .packages[1].platforms[0].version = \"$RELEASE_TAG\" | \
    #    .packages[1].platforms[0].url = \"htts://downloads.arduino.cc/packages/staging/esp32/${core}.zip\" |\
    #    .packages[1].platforms[0].archiveFileName = \"${core}.zip\" |\
    #    .packages[1].platforms[0].size = \"$_PACKAGE_SIZE\" |\
    #    .packages[1].platforms[0].checksum = \"SHA-256:$_PACKAGE_SHA\" |\
    #    .packages[1].platforms[0].boards = $_PACKAGE_BOARDS"

    # TODO: also consider REL package
    #cat ../package/basic_vendor_template.json | jq "$jq_arg" > "$OUTPUT_DIR/$PACKAGE_JSON_DEV"

    jq --arg RELEASE_TAG "$RELEASE_TAG" \
    --arg __PACKAGE_VENDOR "ESP32 $_PACKAGE_VENDOR" \
    --arg _PACKAGE_NAME "esp32 $_PACKAGE_VENDOR" \
    --arg _PACKAGE_MAINTAINER "Espressif Systems - $_PACKAGE_VENDOR" \
    --arg _ARCHIVE_NAME "${core}.zip" \
    --arg _PACKAGE_SHA "SHA-256:$_PACKAGE_SHA" \
    --arg _PACKAGE_SIZE "$_PACKAGE_SIZE" \
    --arg _URL "http://downloads.arduino.cc/cores/staging/esp32/$core.zip" \
    --argjson _PACKAGE_BOARDS "$_PACKAGE_BOARDS" \
    '.packages +=
    [{
      "name": $__PACKAGE_VENDOR,
      "maintainer": $_PACKAGE_MAINTAINER,
      "websiteURL": "https://github.com/espressif/arduino-esp32",
      "email": "hristo@espressif.com",
      "help": {
        "online": "http://esp32.com"
      },
      "platforms": [
        {
          "name": $_PACKAGE_NAME,
          "parent": "esp32",
          "architecture": "esp32",
          "version": $RELEASE_TAG,
          "category": "ESP32",
          "url": $_URL,
          "archiveFileName": $_ARCHIVE_NAME,
          "checksum": $_PACKAGE_SHA,
          "size": $_PACKAGE_SIZE,
          "help": {
            "online": ""
          },
          boards: $_PACKAGE_BOARDS,
          "toolsDependencies": []
        }
      ]
    }]' "$OUTPUT_DIR/$PACKAGE_JSON_DEV" > "$OUTPUT_DIR/"_tmp"$PACKAGE_JSON_DEV"

    mv "$OUTPUT_DIR/"_tmp"$PACKAGE_JSON_DEV" "$OUTPUT_DIR/$PACKAGE_JSON_DEV"

    #jq --arg _PACKAGE_VENDOR "ESP32 $_PACKAGE_VENDOR" \ '.packages[] | select(.name==$_PACKAGE_VENDOR).platforms[0].boards |= "TEST"' "$OUTPUT_DIR/"_tmp"$PACKAGE_JSON_DEV" > "$OUTPUT_DIR/$PACKAGE_JSON_DEV"

    #cat ../package/basic_vendor_template.json |
    #sed "s/%%VERSION%%/${RELEASE_TAG}/" |
    #sed "s/%%FILENAME%%/${core}.zip/" |
    #sed "s/%%CHECKSUM%%/${_PACKAGE_SHA}/" |
    #sed "s/%%VENDOR%%/${_PACKAGE_VENDOR}/" |
    #sed "s/%%BOARDS%%/${_PACKAGE_BOARDS}/" |
    #sed "s/%%SIZE%%/${_PACKAGE_SIZE}/" > package_${core}_index.json

    rm -rf "$core"
done
popd >/dev/null
echo

# Figure out the last release or pre-release
echo "Getting previous releases ..."
releasesJson=`curl -sH "Authorization: token $GITHUB_TOKEN" "https://api.github.com/repos/$GITHUB_REPOSITORY/releases" 2>/dev/null`
if [ $? -ne 0 ]; then echo "ERROR: Get Releases Failed! ($?)"; exit 1; fi

set +e
prev_release=$(echo "$releasesJson" | jq -e -r ". | map(select(.draft == false and .prerelease == false)) | sort_by(.published_at | - fromdateiso8601) | .[0].tag_name")
prev_any_release=$(echo "$releasesJson" | jq -e -r ". | map(select(.draft == false)) | sort_by(.published_at | - fromdateiso8601)  | .[0].tag_name")
prev_branch_release=$(echo "$releasesJson" | jq -e -r ". | map(select(.draft == false and .prerelease == false and .target_commitish == \"$RELEASE_BRANCH\")) | sort_by(.published_at | - fromdateiso8601)  | .[0].tag_name")
prev_branch_any_release=$(echo "$releasesJson" | jq -e -r ". | map(select(.draft == false and .target_commitish == \"$RELEASE_BRANCH\")) | sort_by(.published_at | - fromdateiso8601)  | .[0].tag_name")
shopt -s nocasematch
if [ "$prev_release" == "$RELEASE_TAG" ]; then
    prev_release=$(echo "$releasesJson" | jq -e -r ". | map(select(.draft == false and .prerelease == false)) | sort_by(.published_at | - fromdateiso8601) | .[1].tag_name")
fi
if [ "$prev_any_release" == "$RELEASE_TAG" ]; then
    prev_any_release=$(echo "$releasesJson" | jq -e -r ". | map(select(.draft == false)) | sort_by(.published_at | - fromdateiso8601)  | .[1].tag_name")
fi
if [ "$prev_branch_release" == "$RELEASE_TAG" ]; then
    prev_branch_release=$(echo "$releasesJson" | jq -e -r ". | map(select(.draft == false and .prerelease == false and .target_commitish == \"$RELEASE_BRANCH\")) | sort_by(.published_at | - fromdateiso8601)  | .[1].tag_name")
fi
if [ "$prev_branch_any_release" == "$RELEASE_TAG" ]; then
    prev_branch_any_release=$(echo "$releasesJson" | jq -e -r ". | map(select(.draft == false and .target_commitish == \"$RELEASE_BRANCH\")) | sort_by(.published_at | - fromdateiso8601)  | .[1].tag_name")
fi
shopt -u nocasematch
set -e

echo "Previous Release: $prev_release"
echo "Previous (any)release: $prev_any_release"
echo

# Merge package JSONs with previous releases
if [ ! -z "$prev_any_release" ] && [ "$prev_any_release" != "null" ]; then
    echo "Merging with JSON from $prev_any_release ..."
    merge_package_json "$prev_any_release/$PACKAGE_JSON_DEV" "$OUTPUT_DIR/$PACKAGE_JSON_DEV"
fi

if [ "$RELEASE_PRE" == "false" ]; then
    if [ ! -z "$prev_release" ] && [ "$prev_release" != "null" ]; then
        echo "Merging with JSON from $prev_release ..."
        merge_package_json "$prev_release/$PACKAGE_JSON_REL" "$OUTPUT_DIR/$PACKAGE_JSON_REL"
    fi
fi

# Upload package JSONs
echo "Uploading $PACKAGE_JSON_DEV ..."
echo "Download URL: "`git_safe_upload_asset "$OUTPUT_DIR/$PACKAGE_JSON_DEV"`
echo "Pages URL: "`git_safe_upload_to_pages "$PACKAGE_JSON_DEV" "$OUTPUT_DIR/$PACKAGE_JSON_DEV"`
echo
if [ "$RELEASE_PRE" == "false" ]; then
    echo "Uploading $PACKAGE_JSON_REL ..."
    echo "Download URL: "`git_safe_upload_asset "$OUTPUT_DIR/$PACKAGE_JSON_REL"`
    echo "Pages URL: "`git_safe_upload_to_pages "$PACKAGE_JSON_REL" "$OUTPUT_DIR/$PACKAGE_JSON_REL"`
    echo
fi

##
## RELEASE NOTES
##

# Create release notes
echo "Preparing release notes ..."
releaseNotes=""

# Process annotated tags
relNotesRaw=`git -C "$GITHUB_WORKSPACE" show -s --format=%b $RELEASE_TAG`
readarray -t msgArray <<<"$relNotesRaw"
arrLen=${#msgArray[@]}
if [ $arrLen > 3 ] && [ "${msgArray[0]:0:3}" == "tag" ]; then
    ind=3
    while [ $ind -lt $arrLen ]; do
        if [ $ind -eq 3 ]; then
            releaseNotes="#### ${msgArray[ind]}"
            releaseNotes+=$'\r\n'
        else
            oneLine="$(echo -e "${msgArray[ind]}" | sed -e 's/^[[:space:]]*//')"
            if [ ${#oneLine} -gt 0 ]; then
                if [ "${oneLine:0:2}" == "* " ]; then oneLine=$(echo ${oneLine/\*/-}); fi
                if [ "${oneLine:0:2}" != "- " ]; then releaseNotes+="- "; fi
                releaseNotes+="$oneLine"
                releaseNotes+=$'\r\n'
            fi
        fi
        let ind=$ind+1
    done
fi

# Append Commit Messages
echo
echo "Previous Branch Release: $prev_branch_release"
echo "Previous Branch (any)release: $prev_branch_any_release"
echo
commitFile="$OUTPUT_DIR/commits.txt"
COMMITS_SINCE_RELEASE="$prev_branch_any_release"
if [ "$RELEASE_PRE" == "false" ]; then
    COMMITS_SINCE_RELEASE="$prev_branch_release"
fi
if [ ! -z "$COMMITS_SINCE_RELEASE" ] && [ "$COMMITS_SINCE_RELEASE" != "null" ]; then
    echo "Getting commits since $COMMITS_SINCE_RELEASE ..."
    git -C "$GITHUB_WORKSPACE" log --oneline -n 500 "$COMMITS_SINCE_RELEASE..HEAD" > "$commitFile"
elif [ "$RELEASE_BRANCH" != "master" ]; then
    echo "Getting all commits on branch '$RELEASE_BRANCH' ..."
    git -C "$GITHUB_WORKSPACE" log --oneline -n 500 --cherry-pick --left-only --no-merges HEAD...origin/master > "$commitFile"
else
    echo "Getting all commits on master ..."
    git -C "$GITHUB_WORKSPACE" log --oneline -n 500 --no-merges > "$commitFile"
fi
releaseNotes+=$'\r\n##### Commits\r\n'
IFS=$'\n'
for next in `cat $commitFile`
do
    IFS=' ' read -r commitId commitMsg <<< "$next"
    commitLine="- [$commitId](https://github.com/$GITHUB_REPOSITORY/commit/$commitId) $commitMsg"
    releaseNotes+="$commitLine"
    releaseNotes+=$'\r\n'
done
rm -f $commitFile

# Prepend the original release body
if [ "${RELEASE_BODY: -1}" == $'\r' ]; then
    RELEASE_BODY="${RELEASE_BODY:0:-1}"
else
    RELEASE_BODY="$RELEASE_BODY"
fi
RELEASE_BODY+=$'\r\n'
releaseNotes="$RELEASE_BODY$releaseNotes"

# Update release page
echo "Updating release notes ..."
releaseNotes=$(printf '%s' "$releaseNotes" | python -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
releaseNotes=${releaseNotes:1:-1}
curlData="{\"body\": \"$releaseNotes\"}"
releaseData=`curl --data "$curlData" "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/$RELEASE_ID?access_token=$GITHUB_TOKEN" 2>/dev/null`
if [ $? -ne 0 ]; then echo "ERROR: Updating Release Failed: $?"; exit 1; fi
echo "Release notes successfully updated"
echo

##
## SUBMODULE VERSIONS
##

# Upload submodules versions
echo "Generating submodules.txt ..."
git -C "$GITHUB_WORKSPACE" submodule status > "$OUTPUT_DIR/submodules.txt"
echo "Uploading submodules.txt ..."
echo "Download URL: "`git_safe_upload_asset "$OUTPUT_DIR/submodules.txt"`
echo ""
set +e

##
## DONE
##
echo "DONE!"
