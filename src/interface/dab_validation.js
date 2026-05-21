const POWER_MODES = new Set(["Active", "Standby", "Deep Sleep"]);

const SYSTEM_SETTING_VALIDATORS = {
    language: (value) => typeof value === "string" && value.length > 0,
    outputResolution: (value) => typeof value === "string" && value.length > 0,
    memc: (value) => typeof value === "boolean",
    cec: (value) => typeof value === "boolean",
    lowLatencyMode: (value) => typeof value === "boolean",
    matchContentFrameRate: (value) => typeof value === "string" && value.length > 0,
    hdrOutputMode: (value) => typeof value === "string" && value.length > 0,
    pictureMode: (value) => typeof value === "string" && value.length > 0,
    audioOutputMode: (value) => typeof value === "string" && value.length > 0,
    audioOutputSource: (value) => typeof value === "string" && value.length > 0,
    videoInputSource: (value) => typeof value === "string" && value.length > 0,
    audioVolume: (value) => Number.isInteger(value),
    mute: (value) => typeof value === "boolean",
    timeZone: (value) => typeof value === "string" && value.length > 0,
    textToSpeech: (value) => typeof value === "boolean"
};

function isObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasText(value) {
    return typeof value === "string" && value.trim().length > 0;
}

export function validateInstallAppRequest(data) {
    if (!isObject(data)) return "installApp request must be an object";
    if (!hasText(data.appId)) return "installApp.appId must be a non-empty string";
    if (!hasText(data.url)) return "installApp.url must be a non-empty string";
    if (data.format !== undefined && !hasText(data.format))
        return "installApp.format must be a non-empty string when provided";
    if (data.timeout !== undefined && (!Number.isInteger(data.timeout) || data.timeout < 0))
        return "installApp.timeout must be a non-negative integer when provided";
    return null;
}

export function validateInstallAppFromStoreRequest(data) {
    if (!isObject(data)) return "installAppFromStore request must be an object";
    if (!hasText(data.appId)) return "installAppFromStore.appId must be a non-empty string";
    if (data.appStoreId !== undefined && !hasText(data.appStoreId))
        return "installAppFromStore.appStoreId must be a non-empty string when provided";
    return null;
}

export function validateSetPowerModeRequest(data) {
    if (!isObject(data)) return "setPowerMode request must be an object";
    if (!POWER_MODES.has(data.powerMode))
        return `setPowerMode.powerMode must be one of: ${Array.from(POWER_MODES).join(", ")}`;
    return null;
}

export function validateSetPowerModeResponse(data) {
    if (!isObject(data)) return "setPowerMode response must be an object";
    if (typeof data.status !== "number") return "setPowerMode response.status must be a number";
    if (Math.floor(data.status / 100) === 2 && !POWER_MODES.has(data.powerMode))
        return `setPowerMode response.powerMode must be one of: ${Array.from(POWER_MODES).join(", ")}`;
    return null;
}

export function validateSearchContentRequest(data) {
    if (!isObject(data)) return "searchContent request must be an object";
    if (!hasText(data.searchText)) return "searchContent.searchText must be a non-empty string";
    return null;
}

export function validateSearchContentResponse(data) {
    if (!isObject(data)) return "searchContent response must be an object";
    if (typeof data.status !== "number") return "searchContent response.status must be a number";
    if (Math.floor(data.status / 100) === 2 && !Array.isArray(data.entries))
        return "searchContent response.entries must be an array for successful responses";
    return null;
}

export function validateOpenContentRequest(data) {
    if (!isObject(data)) return "openContent request must be an object";
    if (!hasText(data.entryId) && !hasText(data.contentId))
        return "openContent requires a non-empty entryId (or contentId)";
    return null;
}

export function validateSetSystemSettingsRequest(data) {
    if (!isObject(data)) return "setSystemSettings request must be an object";
    const keys = Object.keys(data);
    if (keys.length === 0) return "setSystemSettings request cannot be empty";

    for (const key of keys) {
        const validator = SYSTEM_SETTING_VALIDATORS[key];
        if (!validator) return `setSystemSettings contains unsupported setting key: ${key}`;
        if (!validator(data[key])) return `setSystemSettings.${key} has invalid value`;
    }
    return null;
}

export function validateDeviceInfoResponse(data) {
    if (!isObject(data)) return "deviceInfo response must be an object";
    if (typeof data.status !== "number") return "deviceInfo response.status must be a number";
    if (Math.floor(data.status / 100) !== 2) return null;

    if ("identifierForAdvertising" in data && data.identifierForAdvertising !== null &&
        !hasText(data.identifierForAdvertising)) {
        return "deviceInfo.identifierForAdvertising must be a non-empty string when provided";
    }
    return null;
}

