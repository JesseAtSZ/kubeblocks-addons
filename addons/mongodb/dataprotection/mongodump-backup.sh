set -e
set -o pipefail
export PATH="$PATH:$DP_DATASAFED_BIN_PATH"
export DATASAFED_BACKEND_BASE_PATH="$DP_BACKUP_BASE_PATH"

trap handle_exit EXIT

# TODO: support endpoint env for sharding cluster.
mongo_uri="mongodb://${DP_DB_HOST}:${DP_DB_PORT}"
START_TIME=$(get_current_time)
mongodump --uri "${mongo_uri}" -u ${DP_DB_USER} -p ${DP_DB_PASSWORD} --authenticationDatabase admin --archive | datasafed push -z zstd-fastest - "${DP_BACKUP_NAME}.archive.zst"

# stat and save the backup information
stat_and_save_backup_info $START_TIME
