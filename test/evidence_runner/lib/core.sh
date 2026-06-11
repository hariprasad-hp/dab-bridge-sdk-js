#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

check_dep() {
    command -v "$1" >/dev/null 2>&1 || {
        ui_write_line "${UI_RED}Missing required command:${UI_RESET} $1" >&2
        exit 1
    }
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
            ui_write_line "${UI_RED}Unsupported BROKER_URI:${UI_RESET} $BROKER_URI" >&2
            ui_write_line "Use format mqtt://host or mqtt://host:port" >&2
            exit 1
            ;;
    esac
}

prepare_paths() {
    LOG_DIR="$LOG_ROOT/$RUN_ID"
    REQ_LOG="$LOG_DIR/requests.log"
    MESSAGE_LOG="$LOG_DIR/messages.log"
    FINAL_JSON="$LOG_DIR/final_results.json"
    RESULTS_TSV="$LOG_DIR/.results.tsv"
    CONSOLE_LOG="$LOG_DIR/console.log"
    TMP_DIR="$LOG_DIR/.tmp"
    mkdir -p "$LOG_DIR"
    mkdir -p "$TMP_DIR"
    touch "$REQ_LOG" "$MESSAGE_LOG" "$RESULTS_TSV" "$CONSOLE_LOG"
}

cleanup_runner() {
    if [[ -n "${MESSAGES_PID:-}" ]] && kill -0 "$MESSAGES_PID" >/dev/null 2>&1; then
        kill "$MESSAGES_PID" >/dev/null 2>&1 || true
        wait "$MESSAGES_PID" 2>/dev/null || true
    fi
}

runner_log() {
    local text="$1"
    ui_log "$text" >>"$CONSOLE_LOG"
}

should_run() {
    local name="$1"
    [[ "$RUN_ONLY" == "all" || "$RUN_ONLY" == "$name" ]]
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
    local stderr_file="$4"
    local mode="$5"
    local sub_rc=0

    set +e
    if [[ "$mode" == "single" ]]; then
        mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -V mqttv5 \
            -C 1 \
            -W "$wait_seconds" \
            -F '%I | %t | %p' \
            -t "$response_topic" >"$output_file" 2>"$stderr_file"
    else
        mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -V mqttv5 \
            -W "$wait_seconds" \
            -F '%I | %t | %p' \
            -t "$response_topic" >"$output_file" 2>"$stderr_file"
    fi
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
        *4*|*5*)
            echo "RESPONDED_WITH_ERROR"
            ;;
        *)
            echo "RESPONDED"
            ;;
    esac
}

record_operation_result() {
    local name="$1"
    local topic="$2"
    local payload="$3"
    local response_topic="$4"
    local wait_seconds="$5"
    local mode="$6"
    local sub_rc="$7"
    local statuses="$8"
    local result="$9"
    local resp_file="${10}"
    local stderr_file="${11}"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" \
        "$topic" \
        "$payload" \
        "$response_topic" \
        "$wait_seconds" \
        "$mode" \
        "$sub_rc" \
        "$statuses" \
        "$result" \
        "$resp_file" \
        "$stderr_file" >>"$RESULTS_TSV"
}

run_operation() {
    local name="$1"
    local topic="$2"
    local payload="$3"
    local wait_seconds="$4"
    local mode="${5:-single}"
    local response_topic="evidence/$RUN_ID/$name"
    local resp_file="$TMP_DIR/${name}.response.log"
    local stderr_file="$TMP_DIR/${name}.stderr.log"
    local statuses=""
    local result=""
    local sub_rc=0

    if ! should_run "$name"; then
        ui_skip "$name" | tee -a "$CONSOLE_LOG"
        return 0
    fi

    : >"$resp_file"
    : >"$stderr_file"

    printf '%s | %s | %s | %s\n' \
        "$(ui_now)" "$name" "$topic" "$payload" >>"$REQ_LOG"

    ui_gtest_run "$name" | tee -a "$CONSOLE_LOG"
    runner_log "RUN $name"

    (
        collect_response "$response_topic" "$wait_seconds" \
            "$resp_file" "$stderr_file" "$mode"
    ) &
    local sub_pid=$!

    sleep 0.2
    publish_request "$topic" "$payload" "$response_topic"

    set +e
    ui_spinner_wait "$sub_pid" "$name"
    sub_rc=$?
    set -e

    statuses="$(extract_statuses "$resp_file")"
    result="$(classify_result "$statuses")"

    case "$result" in
        RESPONDED)
            ui_gtest_ok "$name" "$result" "$statuses" | tee -a "$CONSOLE_LOG"
            ;;
        NOT_IMPLEMENTED|RESPONDED_WITH_ERROR)
            ui_gtest_warn "$name" "$result" "$statuses" | tee -a "$CONSOLE_LOG"
            ;;
        *)
            ui_gtest_fail "$name" "$result" | tee -a "$CONSOLE_LOG"
            ;;
    esac

    runner_log "DONE $name | statuses=$statuses | result=$result"
    record_operation_result \
        "$name" "$topic" "$payload" "$response_topic" "$wait_seconds" \
        "$mode" "$sub_rc" "$statuses" "$result" "$resp_file" \
        "$stderr_file"
}

start_message_capture() {
    mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -V mqttv5 \
        -F '%I | %t | %p' \
        -t "dab/bridge/$BRIDGE_ID/messages" \
        -t "dab/$DEVICE_ID/messages" >"$MESSAGE_LOG" &
    MESSAGES_PID=$!
}

write_final_report() {
    python3 - <<PY
import json
from pathlib import Path

results_path = Path("$RESULTS_TSV")
results = []
summary = {
    "total": 0,
    "responded": 0,
    "responded_with_error": 0,
    "not_implemented": 0,
    "no_response": 0,
}

def load_response_messages(path: Path):
    if not path.exists():
        return []
    messages = []
    for raw_line in path.read_text().splitlines():
        if not raw_line.strip():
            continue
        parts = raw_line.split(" | ", 2)
        entry = {"raw": raw_line}
        if len(parts) == 3:
            entry["timestamp"] = parts[0]
            entry["topic"] = parts[1]
            entry["payload_text"] = parts[2]
            try:
                entry["payload_json"] = json.loads(parts[2])
            except Exception:
                entry["payload_json"] = None
        messages.append(entry)
    return messages

for raw_line in results_path.read_text().splitlines():
    if not raw_line.strip():
        continue
    name, topic, payload, response_topic, wait_seconds, mode, sub_rc, \
        statuses, result, response_log, stderr_log = raw_line.split("\t")
    response_log = Path(response_log)
    stderr_log = Path(stderr_log)

    try:
        request_json = json.loads(payload)
    except Exception:
        request_json = None

    status_list = []
    if statuses and statuses != "NO_RESPONSE":
        status_list = [int(item) for item in statuses.split(",") if item]

    summary["total"] += 1
    if result == "RESPONDED":
        summary["responded"] += 1
    elif result == "RESPONDED_WITH_ERROR":
        summary["responded_with_error"] += 1
    elif result == "NOT_IMPLEMENTED":
        summary["not_implemented"] += 1
    elif result == "NO_RESPONSE":
        summary["no_response"] += 1

    results.append({
        "name": name,
        "request": {
            "topic": topic,
            "payload_text": payload,
            "payload_json": request_json,
            "response_topic": response_topic,
            "wait_seconds": int(wait_seconds),
            "mode": mode,
        },
        "outcome": {
            "result": result,
            "statuses": status_list,
            "subscriber_exit_code": int(sub_rc),
        },
        "response": {
            "messages": load_response_messages(response_log),
            "stderr_text": stderr_log.read_text() if stderr_log.exists() else "",
        },
    })

final_payload = {
    "run": {
        "run_id": "$RUN_ID",
        "broker_uri": "$BROKER_URI",
        "bridge_id": "$BRIDGE_ID",
        "device_id": "$DEVICE_ID",
        "device_ip": "$DEVICE_IP",
        "run_only": "$RUN_ONLY",
    },
    "artifacts": {
        "log_dir": "$LOG_DIR",
        "console_log": "$CONSOLE_LOG",
        "requests_log": "$REQ_LOG",
        "messages_log": "$MESSAGE_LOG",
    },
    "summary": summary,
    "operations": results,
}

Path("$FINAL_JSON").write_text(json.dumps(final_payload, indent=2) + "\\n")
PY

    rm -rf "$TMP_DIR"
    rm -f "$RESULTS_TSV"
}
