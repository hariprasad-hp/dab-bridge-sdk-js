const CONTENT_CATEGORIES = new Set([
    "ContinueWatching",
    "Movies",
    "TvShows",
    "LiveEvents",
    "LinearTv",
    "Video",
    "Trending",
    "Others"
]);

const LEGACY_AND_V21_SETTINGS = {
    language: "language",
    outputResolution: "string",
    memc: "boolean",
    cec: "boolean",
    lowLatencyMode: "boolean",
    matchContentFrameRate: "string",
    hdrOutputMode: "string",
    pictureMode: "string",
    audioOutputMode: "string",
    audioOutputSource: "string",
    videoInputSource: "string",
    audioVolume: "integer",
    mute: "boolean",
    timeZone: "string",
    textToSpeech: "boolean",
    brightness: "integer",
    contrast: "integer",
    screenSaver: "boolean",
    screenSaverTimeout: "integer",
    personalizedAds: "boolean",
    highContrastText: "boolean",
    identifierForAdvertising: "stringOrNull"
};

function isObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isStringArray(value) {
    return Array.isArray(value) && value.every((item) => typeof item === "string");
}

function hasText(value) {
    return typeof value === "string" && value.trim().length > 0;
}

function isRange(value) {
    return isObject(value) && Number.isInteger(value.min) && Number.isInteger(value.max);
}

function isExpectedSettingValue(value, expectedType) {
    if (expectedType === "language") return hasText(value);
    if (expectedType === "string") return hasText(value);
    if (expectedType === "boolean") return typeof value === "boolean";
    if (expectedType === "integer") return Number.isInteger(value);
    if (expectedType === "stringOrNull") return value === null || hasText(value);
    return false;
}

export function validateDabResponse(response) {
    if (!isObject(response)) return "response must be an object";
    if (typeof response.status !== "number") return "response.status must be a number";
    if (Math.floor(response.status / 100) !== 2 && "error" in response && typeof response.error !== "string") {
        return "response.error must be a string when provided";
    }
    return null;
}

export function validateSystemSettingsSetRequest(data) {
    if (!isObject(data)) return "setSystemSettings request must be an object";
    const keys = Object.keys(data);
    if (!keys.length) return "setSystemSettings request cannot be empty";

    for (const key of keys) {
        const expectedType = LEGACY_AND_V21_SETTINGS[key];
        if (!expectedType) return `Unsupported system setting key: ${key}`;
        if (!isExpectedSettingValue(data[key], expectedType)) {
            return `Invalid value for setting '${key}'`;
        }
    }
    return null;
}

export function validateSystemSettingsGetResponse(response) {
    const commonError = validateDabResponse(response);
    if (commonError) return commonError;
    if (Math.floor(response.status / 100) !== 2) return null;

    for (const [key, expectedType] of Object.entries(LEGACY_AND_V21_SETTINGS)) {
        if (key in response && !isExpectedSettingValue(response[key], expectedType)) {
            return `Invalid value type for system setting '${key}'`;
        }
    }
    return null;
}

export function validateSystemSettingsListResponse(response) {
    const commonError = validateDabResponse(response);
    if (commonError) return commonError;
    if (Math.floor(response.status / 100) !== 2) return null;

    const capabilityValidators = {
        language: isStringArray,
        outputResolution: isStringArray,
        memc: (value) => typeof value === "boolean",
        cec: (value) => typeof value === "boolean",
        lowLatencyMode: (value) => typeof value === "boolean",
        matchContentFrameRate: isStringArray,
        hdrOutputMode: isStringArray,
        pictureMode: isStringArray,
        audioOutputMode: isStringArray,
        audioOutputSource: isStringArray,
        videoInputSource: isStringArray,
        audioVolume: isRange,
        mute: (value) => typeof value === "boolean",
        timeZone: (value) => isStringArray(value) || value === true,
        textToSpeech: (value) => typeof value === "boolean",
        brightness: (value) => isRange(value) || typeof value === "boolean",
        contrast: (value) => isRange(value) || typeof value === "boolean",
        screenSaver: (value) => typeof value === "boolean",
        screenSaverTimeout: (value) => isRange(value) || typeof value === "boolean",
        personalizedAds: (value) => typeof value === "boolean",
        highContrastText: (value) => typeof value === "boolean",
        identifierForAdvertising: (value) => typeof value === "boolean"
    };

    for (const [key, value] of Object.entries(response)) {
        if (key === "status" || key === "error") continue;
        const validator = capabilityValidators[key];
        if (!validator) return `Unsupported settings capability key: ${key}`;
        if (!validator(value)) return `Invalid capability value for '${key}'`;
    }
    return null;
}

function validateContentEntry(entry) {
    if (!isObject(entry)) return "content entry must be an object";
    if (!hasText(entry.entryId)) return "content entry.entryId must be a non-empty string";
    if (!hasText(entry.appId)) return "content entry.appId must be a non-empty string";
    if (!hasText(entry.title)) return "content entry.title must be a non-empty string";
    if (!hasText(entry.poster)) return "content entry.poster must be a non-empty string";
    if (!Array.isArray(entry.categories)) return "content entry.categories must be an array";
    for (const category of entry.categories) {
        if (!CONTENT_CATEGORIES.has(category)) {
            return `Unsupported content category '${category}'`;
        }
    }
    return null;
}

export function validateSearchContentRequest(data) {
    if (!isObject(data)) return "searchContent request must be an object";
    if (!hasText(data.searchText)) return "searchContent.searchText must be a non-empty string";
    return null;
}

export function validateOpenContentRequest(data) {
    if (!isObject(data)) return "openContent request must be an object";
    if (!hasText(data.entryId)) return "openContent.entryId must be a non-empty string";
    return null;
}

export function validateContentEntriesResponse(response, operationName) {
    const commonError = validateDabResponse(response);
    if (commonError) return commonError;
    if (Math.floor(response.status / 100) !== 2) return null;
    if (!Array.isArray(response.entries)) return `${operationName} response.entries must be an array`;

    for (const entry of response.entries) {
        const entryError = validateContentEntry(entry);
        if (entryError) return `${operationName} ${entryError}`;
    }
    return null;
}

export function validateSearchContentResponse(response) {
    return validateContentEntriesResponse(response, "searchContent");
}

export function validateContentRecommendationsResponse(response) {
    return validateContentEntriesResponse(response, "contentRecommendations");
}

export { CONTENT_CATEGORIES };

