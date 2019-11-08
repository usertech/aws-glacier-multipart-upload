#!/bin/bash

help() {
    echo
    echo "Uploads large files to AWS S3 Glacier"
    echo
    echo "Options:"
    echo "-f FILE   The file to be uploaded."
    echo "-v VAULT  The name of the Vault that the file will be uploaded into."
    echo
}

[[ -z $1 ]] && help && exit 1
[[ $1 == '--help' ]] && help && exit

while getopts f:v:h arg; do
    case ${arg} in
        f) FILE=${OPTARG} ;;
        v) VAULT=${OPTARG} ;;
        h) help && exit ;;
        *) help && exit 1 ;;
    esac
done

[[ -z $FILE ]] && help && exit 1
[[ -z $VAULT ]] && help && exit 1

byteSize=4194304

gsplit --bytes=$byteSize --verbose $FILE part

# count the number of files that begin with "part"
partCount=$(ls -1 | grep "^part" | wc -l)
echo "Total parts to upload: " $partCount

# get the list of part files to upload.  Edit this if you chose a different prefix in the split command
parts=$(ls | grep "^part")

# initiate multipart upload connection to glacier
init=$(aws glacier initiate-multipart-upload --account-id - --part-size $byteSize --vault-name $VAULT --archive-description "$FILE multipart upload")

echo "---------------------------------------"
# jq pulls out the json element titled uploadId
uploadId=$(echo $init | jq -r '.uploadId')

# create temp file to store commands
touch commands.txt

# create upload commands to be run in parallel and store in commands.txt
i=0
for p in $parts; do
    byteStart=$((i*byteSize))
    partSize=$(wc -c <$p)
    if [[ $partSize == $SIZE ]]; then
        byteEnd=$((byteStart+byteSize-1))
    else
        byteEnd=$((byteStart+partSize-1))
    fi
    echo aws glacier upload-multipart-part --body $p --range \'bytes $byteStart-$byteEnd/*\' --account-id - --vault-name $VAULT --upload-id $uploadId >> commands.txt
    i=$((i+1))
done

# run upload commands in parallel
#   --load 100% option only gives new jobs out if the core is than 100% active
#   -a commands.txt runs every line of that file in parallel, in potentially random order
#   --notice supresses citation output to the console
#   --bar provides a command line progress bar
parallel --load 100% -a commands.txt --no-notice --bar

echo "List Active Multipart Uploads:"
echo "Verify that a connection is open:"
aws glacier list-multipart-uploads --account-id - --vault-name $VAULT

# end the multipart upload
aws glacier abort-multipart-upload --account-id - --vault-name $VAULT --upload-id $uploadId

# list open multipart connections
echo "------------------------------"
echo "List Active Multipart Uploads:"
echo "Verify that the connection is closed:"
aws glacier list-multipart-uploads --account-id - --vault-name $VAULT

echo "--------------"
echo "Deleting temporary commands.txt file and the part files"
rm commands.txt part*
