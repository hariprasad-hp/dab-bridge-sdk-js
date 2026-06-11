#!/usr/bin/env bash

set -u

BROKER_URI="${BROKER_URI:-mqtt://127.0.0.1:1883}"
BRIDGE_ID="${BRIDGE_ID:-template}"
DEVICE_ID="${DEVICE_ID:-test-device}"
DEVICE_IP="${DEVICE_IP:-127.0.0.1}"
LOG_ROOT="${LOG_ROOT:-test/evidence}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
WAIT_SHORT="${WAIT_SHORT:-3}"
WAIT_MEDIUM="${WAIT_MEDIUM:-8}"
WAIT_LONG="${WAIT_LONG:-20}"

LOG_DIR="$LOG_ROOT/$RUN_ID"
REQ_LOG="$LOG_DIR/requests.log"
SUMMARY_LOG="$LOG_DIR/summary.log"
MESSAGE_LOG="$LOG_DIR/messages.log"
MESSAGES_PID=""
MQTT_HOST=""
MQTT_PORT=""

check_dep() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required command: $1" >&2
        exit 1
    }
}

cleanup() {
    if [[ -n "$MESSAGES_PID" ]] && kill -0 "$MESSAGES_PID" >/dev/null 2>&1; then
        kill "$MESSAGES_PID" >/dev/null 2>&1 || true
        wait "$MESSAGES_PID" 2>/dev/null || true
    fi
}

parse_broker_uri() {
    case "$BROKER_URI" in
        mqtt://*)
            local remainder="${BROKER_URI#mqtt://}"
            MQTT_HOST="${remainder%%:*}"
            MQTT_PORT="${remainder##*:}"
            if [[ "$MQTT_HOST" == "$MQTT_PORT" ]]; then
                MQTT_PORT="1883"
            fi
            ;;
        *)
            echo "Unsupported BROKER_URI: $BROKER_URI" >&2
            echo "Use format mqtt://host or mqtt://host:port" >&2
            exit 1
            ;;
    esac
}

log_line() {
    printf '%s | %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" | tee -a "$SUMMARY_LOG"
}

publish_request() {
    local topic="$1"
    local payload="$2"
    local response_topic="$3"

    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -V mqttv5 \
        -t "$topic" \
        -m "$payload" \
        -D publish response-topic "$response_topic"
}

collect_response() {
    local response_topic="$1"
    local wait_seconds="$2"
    local output_file="$3"
    local stderr_file="${4:-/dev/null}"
    local sub_rc=0

    set +e
    mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -V mqttv5 \
        -W "$wait_seconds" \
        -F '%I | %t | %p' \
        -t "$response_topic" >"$output_file" 2>"$stderr_file"
    sub_rc=$?
    set -e

    return "$sub_rc"
}

extract_statuses() {
    local input_file="$1"

    if [[ ! -s "$input_file" ]]; then
        echo "NO_RESPONSE"
        return
    fi

    grep -o '"status":[[:space:]]*[0-9]\+' "$input_file" \
        | sed 's/.*://; s/[[:space:]]//g' \
        | paste -sd ',' -
}

classify_result() {
    local statuses="$1"

    case "$statuses" in
        NO_RESPONSE)
            echo "NO_RESPONSE"
            ;;
        *501*)
            echo "NOT_IMPLEMENTED"
            ;;
        *)
            echo "RESPONDED"
            ;;
    esac
}

run_operation() {
    local name="$1"
    local topic="$2"
    local payload="$3"
    local wait_seconds="$4"
    local response_topic="evidence/$RUN_ID/$name"
    local op_dir="$LOG_DIR/$name"
    local req_file="$op_dir/request.json"
    local resp_file="$op_dir/response.log"
    local stderr_file="$op_dir/subscriber.stderr.log"
    local meta_file="$op_dir/meta.txt"
    local statuses=""
    local result=""
    local sub_rc=0

    mkdir -p "$op_dir"
    printf '%s\n' "$payload" >"$req_file"
    {
        echo "name=$name"
        echo "request_topic=$topic"
        echo "response_topic=$response_topic"
        echo "wait_seconds=$wait_seconds"
    } >"$meta_file"

    printf '%s | %s | %s | %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$name" \
        "$topic" \
        "$payload" >>"$REQ_LOG"

    log_line "RUN $name"

    (
        collect_response "$response_topic" "$wait_seconds" \
            "$resp_file" "$stderr_file"
    ) &
    local sub_pid=$!

    sleep 0.2
    publish_request "$topic" "$payload" "$response_topic"

    set +e
    wait "$sub_pid"
    sub_rc=$?
    set -e

    statuses="$(extract_statuses "$resp_file")"
    result="$(classify_result "$statuses")"

    {
        echo "subscriber_exit_code=$sub_rc"
        echo "statuses=$statuses"
        echo "result=$result"
        echo "subscriber_stderr=$stderr_file"
    } >>"$meta_file"

    log_line "DONE $name | statuses=$statuses | result=$result"
}

check_dep mosquitto_pub
check_dep mosquitto_sub
parse_broker_uri

mkdir -p "$LOG_DIR"
touch "$REQ_LOG" "$SUMMARY_LOG" "$MESSAGE_LOG"

trap cleanup EXIT

set -e

log_line "Starting evidence run in $LOG_DIR"
log_line "Broker: $BROKER_URI"
log_line "Bridge: $BRIDGE_ID"
log_line "Device: $DEVICE_ID"

mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -V mqttv5 \
    -F '%I | %t | %p' \
    -t "dab/bridge/$BRIDGE_ID/messages" \
    -t "dab/$DEVICE_ID/messages" >"$MESSAGE_LOG" &
MESSAGES_PID=$!

run_operation \
    "bridge_add_device" \
    "dab/bridge/$BRIDGE_ID/add-device" \
    "{ \"ip\": \"$DEVICE_IP\", \"skipValidation\": true, \"dabDeviceId\": \"$DEVICE_ID\" }" \
    "$WAIT_MEDIUM"

run_operation \
    "bridge_list_devices" \
    "dab/bridge/$BRIDGE_ID/list-devices" \
    "{}" \
    "$WAIT_SHORT"

run_operation \
    "discovery" \
    "dab/discovery" \
    "{}" \
    "$WAIT_SHORT"

run_operation \
    "operations_list" \
    "dab/$DEVICE_ID/operations/list" \
    "{}" \
    "$WAIT_SHORT"

run_operation \
    "version" \
    "dab/$DEVICE_ID/version" \
    "{}" \
    "$WAIT_SHORT"

run_operation \
    "device_info" \
    "dab/$DEVICE_ID/device/info" \
    "{}" \
    "$WAIT_SHORT"

run_operation \
    "health_check" \
    "dab/$DEVICE_ID/health-check/get" \
    "{}" \
    "$WAIT_SHORT"

run_operation \
    "applications_list" \
    "dab/$DEVICE_ID/applications/list" \
    "{}" \
    "$WAIT_SHORT"

run_operation \
    "applications_launch" \
    "dab/$DEVICE_ID/applications/launch" \
    '{ "appId": "YouTube" }' \
    "$WAIT_SHORT"

run_operation \
    "applications_launch_with_content" \
    "dab/$DEVICE_ID/applications/launch-with-content" \
    '{ "appId": "YouTube", "contentId": "demo-content" }' \
    "$WAIT_SHORT"

run_operation \
    "applications_get_state" \
    "dab/$DEVICE_ID/applications/get-state" \
    '{ "appId": "YouTube" }' \
    "$WAIT_SHORT"

run_operation \
    "applications_exit" \
    "dab/$DEVICE_ID/applications/exit" \
    '{ "appId": "YouTube" }' \
    "$WAIT_SHORT"

run_operation \
    "applications_install" \
    "dab/$DEVICE_ID/applications/install" \
    '{ "appId": "YouTube", "url": "https://example.com/app.pkg" }' \
    "$WAIT_LONG"

run_operation \
    "applications_uninstall" \
    "dab/$DEVICE_ID/applications/uninstall" \
    '{ "appId": "YouTube" }' \
    "$WAIT_MEDIUM"

run_operation \
    "applications_clear_data" \
    "dab/$DEVICE_ID/applications/clear-data" \
    '{ "appId": "YouTube" }' \
    "$WAIT_MEDIUM"

run_operation \
    "applications_install_from_app_store" \
    "dab/$DEVICE_ID/applications/install-from-app-store" \
    '{ "appId": "YouTube", "appStoreId": "store-id" }' \
    "$WAIT_LONG"

run_operation \
    "system_restart" \
    "dab/$DEVICE_ID/system/restart" \
    "{}" \
    "$WAIT_SHORT"

run_operation \
    "system_power_mode_get" \
    "dab/$DEVICE_ID/system/power-mode/get" \
    "{}" \
    "$WAIT_SHORT"

run_operation \
    "system_power_mode_set" \
    "dab/$DEVICE_ID/system/power-mode/set" \
    '{ "powerMode": "Standby" }' \
    "$WAIT_SHORT"

run_operation \
    "system_factory_reset" \
    "dab/$DEVICE_ID/system/factory-reset" \
    "{}" \
    "$WAIT_LONG"

run_operation \
    "system_network_reset" \
    "dab/$DEVICE_ID/system/network-reset" \
    "{}" \
    "$WAIT_MEDIUM"

run_operation \
    "system_settings_list" \
    "dab/$DEVICE_ID/system/settings/list" \
    "{}" \
    "$WAIT_SHORT"

run_operation \
    "system_settings_get" \
    "dab/$DEVICE_ID/system/settings/get" \
    "{}" \
    "$WAIT_SHORT"

run_operation \
    "system_settings_set" \
    "dab/$DEVICE_ID/system/settings/set" \
    '{ "brightness": 50, "screenSaver": true }' \
    "$WAIT_SHORT"

run_operation \
    "system_logs_start_collection" \
    "dab/$DEVICE_ID/system/logs/start-collection" \
    "{}" \
    "$WAIT_SHORT"

run_operation \
    "system_logs_stop_collection" \
    "dab/$DEVICE_ID/system/logs/stop-collection" \
    "{}" \
    "$WAIT_MEDIUM"

run_operation \
    "input_key_list" \
    "dab/$DEVICE_ID/input/key/list" \
    "{}" \
    "$WAIT_SHORT"

run_operation \
    "input_key_press" \
    "dab/$DEVICE_ID/input/key-press" \
    '{ "keyCode": "KEY_HOME" }' \
    "$WAIT_SHORT"

run_operation \
    "input_long_key_press" \
    "dab/$DEVICE_ID/input/long-key-press" \
    '{ "keyCode": "KEY_BACK", "durationMs": 2000 }' \
    "$WAIT_SHORT"

run_operation \
    "output_image" \
    "dab/$DEVICE_ID/output/image" \
    '{ "outputLocation": "http://127.0.0.1/image.png" }' \
    "$WAIT_SHORT"

run_operation \
    "content_search" \
    "dab/$DEVICE_ID/content/search" \
    '{ "searchText": "home" }' \
    "$WAIT_SHORT"

run_operation \
    "content_recommendations" \
    "dab/$DEVICE_ID/content/recommendations" \
    "{}" \
    "$WAIT_SHORT"

run_operation \
    "content_open" \
    "dab/$DEVICE_ID/content/open" \
    '{ "entryId": "entry-1" }' \
    "$WAIT_SHORT"

run_operation \
    "device_telemetry_start" \
    "dab/$DEVICE_ID/device-telemetry/start" \
    '{ "duration": 1000 }' \
    "$WAIT_SHORT"

run_operation \
    "device_telemetry_stop" \
    "dab/$DEVICE_ID/device-telemetry/stop" \
    "{}" \
    "$WAIT_SHORT"

run_operation \
    "app_telemetry_start" \
    "dab/$DEVICE_ID/app-telemetry/start" \
    '{ "appId": "YouTube", "duration": 1000 }' \
    "$WAIT_SHORT"

run_operation \
    "app_telemetry_stop" \
    "dab/$DEVICE_ID/app-telemetry/stop" \
    '{ "appId": "YouTube" }' \
    "$WAIT_SHORT"

run_operation \
    "voice_list" \
    "dab/$DEVICE_ID/voice/list" \
    "{}" \
    "$WAIT_SHORT"

run_operation \
    "voice_set" \
    "dab/$DEVICE_ID/voice/set" \
    '{ "voiceSystem": { "name": "AmazonAlexa", "enabled": true } }' \
    "$WAIT_SHORT"

run_operation \
    "voice_send_text" \
    "dab/$DEVICE_ID/voice/send-text" \
    '{ "requestText": "Play music", "voiceSystem": "AmazonAlexa" }' \
    "$WAIT_SHORT"

run_operation \
    "voice_send_audio" \
    "dab/$DEVICE_ID/voice/send-audio" \
    '{ "fileLocation": "http://127.0.0.1/test.wav", "voiceSystem": "AmazonAlexa" }' \
    "$WAIT_SHORT"

run_operation \
    "bridge_remove_device" \
    "dab/bridge/$BRIDGE_ID/remove-device" \
    "{ \"ip\": \"$DEVICE_IP\" }" \
    "$WAIT_MEDIUM"

log_line "Evidence run completed"
log_line "Requests log: $REQ_LOG"
log_line "Messages log: $MESSAGE_LOG"
log_line "Per-operation evidence: $LOG_DIR/*"
