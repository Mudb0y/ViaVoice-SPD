/*
 * sd_viavoice.c - Speech Dispatcher module for IBM ViaVoice TTS 5.1
 *
 * Copyright (C) 2025
 * Based on skeleton0.c by Samuel Thibault (BSD license)
 * 
 * This is a native 32-bit module for ViaVoice TTS 5.1 (1999-2000).
 * It uses the ECI (Eloquence Command Interface) API directly.
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <pthread.h>
#include <errno.h>

#include "spd_module_main.h"
#include "eci_viavoice.h"

/* Debug output */
#define DBG(fmt, ...) fprintf(stderr, "sd_viavoice: " fmt "\n", ##__VA_ARGS__)

/* Module state */
static ECIHand eciHandle = NULL_ECI_HAND;
static short *audio_buffer = NULL;
static int audio_buffer_size = 20000;
static volatile int stop_requested = 0;
static int eci_sample_rate = 22050;
static int config_sample_rate = 2;  /* 0=8000, 1=11025, 2=22050 (default) */

/* Custom voice parameters (applied on top of preset voice) */
static int config_pitch_baseline = -1;   /* -1 = use voice default */
static int config_pitch_fluctuation = -1;
static int config_speed = -1;
static int config_volume = -1;
static int config_head_size = -1;
static int config_roughness = -1;
static int config_breathiness = -1;

/* Dictionary paths */
static char config_main_dict[256] = "";
static char config_root_dict[256] = "";
static char config_abbrev_dict[256] = "";

/* Global ECI parameters */
static int config_phrase_prediction = 0;  /* 0 = disabled by default */
static int config_number_mode = -1;
static int config_text_mode = -1;
static int config_real_world_units = -1;

/* Dictionary handle */
static ECIDictHand dictHandle = NULL_DICT_HAND;

/* Voice settings — the voice is fixed at init from viavoice.conf */
static int config_voice = 0;   /* 0-7 ViaVoice preset, set via ViaVoiceDefaultVoice */
static int current_rate = 50;  /* 0-250, default 50 */
static int current_pitch = 65; /* 0-100, default 65 */
static int current_volume = 90;

static const char *voice_name_table[] = {
    "Wade", "Flo", "Bobbie", "Male2", "Male3", "Female2", "Grandma", "Grandpa"
};

/* Collected audio data */
typedef struct {
    short *samples;
    int num_samples;
    int allocated;
} AudioData;

static AudioData audio_data = {NULL, 0, 0};
static pthread_mutex_t audio_mutex = PTHREAD_MUTEX_INITIALIZER;

/* ECI callback for receiving synthesized audio */
static ECICallbackReturn eci_callback(ECIHand hECI, ECIMessage msg, long param, void *data)
{
    (void)hECI;
    (void)data;
    
    /* ViaVoice doesn't have eciDataAbort, just return not processed to signal stop */
    if (stop_requested)
        return eciDataNotProcessed;
    
    if (msg == eciWaveformBuffer) {
        pthread_mutex_lock(&audio_mutex);
        
        int new_samples = param;
        int new_size = audio_data.num_samples + new_samples;
        
        if (new_size > audio_data.allocated) {
            int alloc_size = new_size + audio_buffer_size;
            audio_data.samples = realloc(audio_data.samples, alloc_size * sizeof(short));
            if (!audio_data.samples) {
                pthread_mutex_unlock(&audio_mutex);
                return eciDataNotProcessed;
            }
            audio_data.allocated = alloc_size;
        }
        
        memcpy(audio_data.samples + audio_data.num_samples, 
               audio_buffer, new_samples * sizeof(short));
        audio_data.num_samples = new_size;
        
        pthread_mutex_unlock(&audio_mutex);
    }
    
    return eciDataProcessed;
}

int module_config(const char *configfile)
{
    DBG("loading config: %s", configfile ? configfile : "(none)");
    
    if (!configfile) return 0;
    
    FILE *f = fopen(configfile, "r");
    if (!f) {
        DBG("Could not open config file: %s", strerror(errno));
        return 0;  /* Not fatal - use defaults */
    }
    DBG("Config file opened successfully");
    
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        /* Skip comments and empty lines */
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == '\0') continue;
        
        /* Parse key-value pairs */
        char key[64], value[64];
        if (sscanf(p, "%63s %63s", key, value) == 2) {
            DBG("Config line: key='%s' value='%s'", key, value);
            if (strcasecmp(key, "ViaVoiceSampleRate") == 0) {
                int rate = atoi(value);
                DBG("Parsed sample rate: %d", rate);
                if (rate == 8000) config_sample_rate = 0;
                else if (rate == 11025) config_sample_rate = 1;
                else if (rate == 22050) config_sample_rate = 2;
                else {
                    /* Accept raw codes 0, 1, 2 as well */
                    if (rate >= 0 && rate <= 2) config_sample_rate = rate;
                }
                DBG("Config: sample rate code %d", config_sample_rate);
            }
            else if (strcasecmp(key, "ViaVoiceDefaultVoice") == 0) {
                int v = atoi(value);
                if (v >= 0 && v <= 7) {
                    config_voice = v;
                    DBG("Config: voice %d (%s)", config_voice, voice_name_table[config_voice]);
                }
            }
            else if (strcasecmp(key, "ViaVoicePitchBaseline") == 0) {
                int v = atoi(value);
                if (v >= 0 && v <= 100) {
                    config_pitch_baseline = v;
                    DBG("Config: pitch baseline %d", v);
                }
            }
            else if (strcasecmp(key, "ViaVoicePitchFluctuation") == 0) {
                int v = atoi(value);
                if (v >= 0 && v <= 100) {
                    config_pitch_fluctuation = v;
                    DBG("Config: pitch fluctuation %d", v);
                }
            }
            else if (strcasecmp(key, "ViaVoiceSpeed") == 0) {
                int v = atoi(value);
                if (v >= 0 && v <= 250) {
                    config_speed = v;
                    DBG("Config: speed %d", v);
                }
            }
            else if (strcasecmp(key, "ViaVoiceVolume") == 0) {
                int v = atoi(value);
                if (v >= 0 && v <= 100) {
                    config_volume = v;
                    DBG("Config: volume %d", v);
                }
            }
            else if (strcasecmp(key, "ViaVoiceHeadSize") == 0) {
                int v = atoi(value);
                if (v >= 0 && v <= 100) {
                    config_head_size = v;
                    DBG("Config: head size %d", v);
                }
            }
            else if (strcasecmp(key, "ViaVoiceRoughness") == 0) {
                int v = atoi(value);
                if (v >= 0 && v <= 100) {
                    config_roughness = v;
                    DBG("Config: roughness %d", v);
                }
            }
            else if (strcasecmp(key, "ViaVoiceBreathiness") == 0) {
                int v = atoi(value);
                if (v >= 0 && v <= 100) {
                    config_breathiness = v;
                    DBG("Config: breathiness %d", v);
                }
            }
            else if (strcasecmp(key, "ViaVoiceMainDict") == 0) {
                strncpy(config_main_dict, value, sizeof(config_main_dict) - 1);
                config_main_dict[sizeof(config_main_dict) - 1] = '\0';
                DBG("Config: main dictionary %s", config_main_dict);
            }
            else if (strcasecmp(key, "ViaVoiceRootDict") == 0) {
                strncpy(config_root_dict, value, sizeof(config_root_dict) - 1);
                config_root_dict[sizeof(config_root_dict) - 1] = '\0';
                DBG("Config: root dictionary %s", config_root_dict);
            }
            else if (strcasecmp(key, "ViaVoiceAbbrevDict") == 0) {
                strncpy(config_abbrev_dict, value, sizeof(config_abbrev_dict) - 1);
                config_abbrev_dict[sizeof(config_abbrev_dict) - 1] = '\0';
                DBG("Config: abbreviation dictionary %s", config_abbrev_dict);
            }
            else if (strcasecmp(key, "ViaVoicePhrasePrediction") == 0) {
                int v = atoi(value);
                if (v >= 0 && v <= 1) {
                    config_phrase_prediction = v;
                    DBG("Config: phrase prediction %d", v);
                }
            }
            else if (strcasecmp(key, "ViaVoiceNumberMode") == 0) {
                int v = atoi(value);
                if (v >= 0) {
                    config_number_mode = v;
                    DBG("Config: number mode %d", v);
                }
            }
            else if (strcasecmp(key, "ViaVoiceTextMode") == 0) {
                int v = atoi(value);
                if (v >= 0) {
                    config_text_mode = v;
                    DBG("Config: text mode %d", v);
                }
            }
            else if (strcasecmp(key, "ViaVoiceRealWorldUnits") == 0) {
                int v = atoi(value);
                if (v >= 0 && v <= 1) {
                    config_real_world_units = v;
                    DBG("Config: real world units %d", v);
                }
            }
        }
    }
    fclose(f);
    return 0;
}

int module_init(char **msg)
{
    DBG("initializing ViaVoice TTS");
    
    /* Tell server we'll send audio to it */
    module_audio_set_server();
    
    /* Create ECI instance */
    eciHandle = eciNew();
    if (eciHandle == NULL_ECI_HAND) {
        *msg = strdup("Failed to create ECI instance - check ViaVoice installation");
        return -1;
    }
    
    /* Allocate audio buffer */
    audio_buffer = malloc(audio_buffer_size * sizeof(short));
    if (!audio_buffer) {
        eciDelete(eciHandle);
        eciHandle = NULL_ECI_HAND;
        *msg = strdup("Failed to allocate audio buffer");
        return -1;
    }
    
    /* Register callback and set output buffer */
    eciRegisterCallback(eciHandle, eci_callback, NULL);
    
    if (!eciSetOutputBuffer(eciHandle, audio_buffer_size, audio_buffer)) {
        free(audio_buffer);
        audio_buffer = NULL;
        eciDelete(eciHandle);
        eciHandle = NULL_ECI_HAND;
        *msg = strdup("Failed to set ECI output buffer");
        return -1;
    }
    
    /* Set sample rate from config (default 22050 Hz) */
    eciSetParam(eciHandle, eciSampleRate, config_sample_rate);
    
    /* Read back the actual sample rate */
    int rate_code = eciGetParam(eciHandle, eciSampleRate);
    switch (rate_code) {
        case 0: eci_sample_rate = 8000; break;
        case 1: eci_sample_rate = 11025; break;
        case 2: eci_sample_rate = 22050; break;
        default: eci_sample_rate = 22050;
    }
    
    DBG("initialized, sample rate %d Hz", eci_sample_rate);
    
    /* Apply custom voice parameters from config to the selected voice */
    if (config_pitch_baseline >= 0)
        eciSetVoiceParam(eciHandle, config_voice, eciPitchBaseline, config_pitch_baseline);
    if (config_pitch_fluctuation >= 0)
        eciSetVoiceParam(eciHandle, config_voice, eciPitchFluctuation, config_pitch_fluctuation);
    if (config_speed >= 0)
        eciSetVoiceParam(eciHandle, config_voice, eciSpeed, config_speed);
    if (config_volume >= 0)
        eciSetVoiceParam(eciHandle, config_voice, eciVolume, config_volume);
    if (config_head_size >= 0)
        eciSetVoiceParam(eciHandle, config_voice, eciHeadSize, config_head_size);
    if (config_roughness >= 0)
        eciSetVoiceParam(eciHandle, config_voice, eciRoughness, config_roughness);
    if (config_breathiness >= 0)
        eciSetVoiceParam(eciHandle, config_voice, eciBreathiness, config_breathiness);

    /* Copy configured voice to voice 0 (the active synthesis voice) */
    if (config_voice != 0)
        eciCopyVoice(eciHandle, config_voice, 0);
    
    /* Apply global ECI parameters from config */
    if (config_phrase_prediction >= 0) {
        eciSetParam(eciHandle, eciPhrasePrediction, config_phrase_prediction);
        DBG("Set phrase prediction: %d", config_phrase_prediction);
    }
    if (config_number_mode >= 0) {
        eciSetParam(eciHandle, eciNumberMode, config_number_mode);
        DBG("Set number mode: %d", config_number_mode);
    }
    if (config_text_mode >= 0) {
        eciSetParam(eciHandle, eciTextMode, config_text_mode);
        DBG("Set text mode: %d", config_text_mode);
    }
    if (config_real_world_units >= 0) {
        eciSetParam(eciHandle, eciRealWorldUnits, config_real_world_units);
        DBG("Set real world units: %d", config_real_world_units);
    }
    
    /* Load dictionaries if specified */
    if (config_main_dict[0] != '\0' || config_root_dict[0] != '\0' || config_abbrev_dict[0] != '\0') {
        dictHandle = eciNewDict(eciHandle);
        if (dictHandle != NULL_DICT_HAND) {
            ECIDictError err;
            
            if (config_main_dict[0] != '\0') {
                err = eciLoadDict(eciHandle, dictHandle, eciMainDict, config_main_dict);
                if (err == DictNoError) {
                    DBG("Loaded main dictionary: %s", config_main_dict);
                } else {
                    DBG("Failed to load main dictionary: %s (error %d)", config_main_dict, err);
                }
            }
            
            if (config_root_dict[0] != '\0') {
                err = eciLoadDict(eciHandle, dictHandle, eciRootDict, config_root_dict);
                if (err == DictNoError) {
                    DBG("Loaded root dictionary: %s", config_root_dict);
                } else {
                    DBG("Failed to load root dictionary: %s (error %d)", config_root_dict, err);
                }
            }
            
            if (config_abbrev_dict[0] != '\0') {
                err = eciLoadDict(eciHandle, dictHandle, eciAbbvDict, config_abbrev_dict);
                if (err == DictNoError) {
                    DBG("Loaded abbreviation dictionary: %s", config_abbrev_dict);
                } else {
                    DBG("Failed to load abbreviation dictionary: %s (error %d)", config_abbrev_dict, err);
                }
            }
            
            /* Activate the dictionary */
            err = eciSetDict(eciHandle, dictHandle);
            if (err == DictNoError) {
                DBG("Dictionary activated");
            } else {
                DBG("Failed to activate dictionary (error %d)", err);
            }
        } else {
            DBG("Failed to create dictionary handle");
        }
    }
    
    *msg = strdup("ViaVoice TTS initialized successfully");
    return 0;
}

SPDVoice **module_list_voices(void)
{
    SPDVoice **voices = malloc(2 * sizeof(SPDVoice*));
    if (!voices) return NULL;

    voices[0] = malloc(sizeof(SPDVoice));
    if (!voices[0]) { free(voices); return NULL; }
    voices[0]->name = strdup(voice_name_table[config_voice]);
    voices[0]->language = strdup("en-US");
    voices[0]->variant = strdup("none");
    voices[1] = NULL;

    return voices;
}

int module_set(const char *var, const char *val)
{
    DBG("set %s = %s", var, val);
    
    if (!strcmp(var, "voice") || !strcmp(var, "synthesis_voice") || !strcmp(var, "language")) {
        /* Voice is fixed from viavoice.conf; ignore runtime changes */
        return 0;
    } else if (!strcmp(var, "rate")) {
        /* SPD rate: -100 to +100, ViaVoice: 0-250 */
        int spd_rate = atoi(val);
        current_rate = ((spd_rate + 100) * 250) / 200;
        if (current_rate < 0) current_rate = 0;
        if (current_rate > 250) current_rate = 250;
        return 0;
    } else if (!strcmp(var, "pitch")) {
        /* SPD pitch: -100 to +100, ViaVoice: 0-100 */
        int spd_pitch = atoi(val);
        current_pitch = (spd_pitch + 100) / 2;
        if (current_pitch < 0) current_pitch = 0;
        if (current_pitch > 100) current_pitch = 100;
        return 0;
    } else if (!strcmp(var, "volume")) {
        /* SPD volume: -100 to +100, ViaVoice: 0-100 */
        int spd_vol = atoi(val);
        current_volume = (spd_vol + 100) / 2;
        if (current_volume < 0) current_volume = 0;
        if (current_volume > 100) current_volume = 100;
        return 0;
    }
    /* Accept all parameters - ignore ones we don't handle */
    return 0;
}

int module_audio_set(const char *var, const char *val)
{
    (void)var;
    (void)val;
    /* We use server audio output */
    return 0;
}

int module_audio_init(char **status)
{
    *status = strdup("Using server audio");
    return 0;
}

int module_loglevel_set(const char *var, const char *val)
{
    (void)var;
    (void)val;
    return 0;
}

int module_debug(int enable, const char *file)
{
    (void)enable;
    (void)file;
    return 0;
}

int module_loop(void)
{
    DBG("entering main loop");
    int ret = module_process(STDIN_FILENO, 1);
    if (ret != 0)
        DBG("broken pipe, exiting");
    return ret;
}

/* Decode XML entities in-place: &amp; &lt; &gt; &apos; &quot; */
static void decode_xml_entities(char *text)
{
    static const struct { const char *entity; char ch; int len; } entities[] = {
        { "&amp;",  '&',  5 },
        { "&lt;",   '<',  4 },
        { "&gt;",   '>',  4 },
        { "&apos;", '\'', 6 },
        { "&quot;", '"',  6 },
    };

    char *src = text, *dst = text;
    while (*src) {
        if (*src == '&') {
            int matched = 0;
            for (int e = 0; e < 5; e++) {
                if (strncmp(src, entities[e].entity, entities[e].len) == 0) {
                    *dst++ = entities[e].ch;
                    src += entities[e].len;
                    matched = 1;
                    break;
                }
            }
            if (!matched)
                *dst++ = *src++;
        } else {
            *dst++ = *src++;
        }
    }
    *dst = '\0';
}

/* Strip SSML/XML tags from text - ViaVoice doesn't understand SSML */
static char *strip_ssml(const char *text, size_t len)
{
    char *result = malloc(len + 1);
    if (!result) return NULL;

    size_t j = 0;
    int in_tag = 0;

    for (size_t i = 0; i < len; i++) {
        if (text[i] == '<') {
            in_tag = 1;
        } else if (text[i] == '>') {
            in_tag = 0;
        } else if (!in_tag) {
            result[j++] = text[i];
        }
    }
    result[j] = '\0';

    /* Decode XML entities (e.g. &apos; -> ') */
    decode_xml_entities(result);

    /* Trim leading/trailing whitespace */
    char *start = result;
    while (*start && (*start == ' ' || *start == '\n' || *start == '\t')) start++;

    j = strlen(result);
    if (j == 0) return result;
    char *end = result + j - 1;
    while (end > start && (*end == ' ' || *end == '\n' || *end == '\t')) end--;
    *(end + 1) = '\0';

    /* If we trimmed from the start, move the string */
    if (start != result) {
        memmove(result, start, strlen(start) + 1);
    }

    return result;
}

/*
 * Sanitize text for ViaVoice (plain text mode).  Returns a new
 * malloc'd string (caller frees).  Clause-break characters become
 * commas attached to the preceding word so ViaVoice uses natural
 * inflection instead of reading punctuation aloud.
 */
static char *sanitize_for_viavoice(const char *text)
{
    size_t len = strlen(text);
    /* Each clause-break char can expand to ", " (2 bytes) so worst
     * case output is 2*len.  Generous but safe. */
    char *out = malloc(len * 2 + 1);
    if (!out) return NULL;

    const unsigned char *src = (const unsigned char *)text;
    char *dst = out;

    while (*src) {
        unsigned char c = *src;

        if (c < 0x80) {
            if ((c >= 'A' && c <= 'Z') ||
                (c >= 'a' && c <= 'z') ||
                (c >= '0' && c <= '9') ||
                c == ' ' || c == '\t' || c == '\n' ||
                c == '.' || c == ',' || c == '!' || c == '?' ||
                c == '$' || c == '\'') {
                *dst++ = c;
                src++;
                continue;
            }

            /* Clause-break punctuation → comma attached to preceding word */
            if (c == ';' || c == ':' ||
                c == '(' || c == ')' ||
                c == '[' || c == ']' ||
                c == '{' || c == '}') {
                while (dst > out && (*(dst-1) == ' ' || *(dst-1) == '\t'))
                    dst--;
                /* Only insert comma if there's a preceding word to attach to */
                if (dst > out)
                    *dst++ = ',';
                src++;
                /* Skip trailing punctuation that would end up isolated (e.g. ").") */
                while (*src == '.' || *src == ',' || *src == '!' ||
                       *src == '?' || *src == ';' || *src == ':') src++;
                while (*src == ' ' || *src == '\t') src++;
                *dst++ = ' ';
                continue;
            }

            *dst++ = ' ';
            src++;
            continue;
        }

        /* Multi-byte UTF-8 */
        int seqlen;
        if (c < 0xE0)      seqlen = 2;
        else if (c < 0xF0)  seqlen = 3;
        else                 seqlen = 4;

        int valid = 1;
        for (int i = 1; i < seqlen; i++) {
            if (!src[i]) { valid = 0; break; }
        }
        if (!valid) { src++; continue; }

        /* Currency symbols → English word (ViaVoice is too old for UTF-8) */
        if (seqlen == 2 && c == 0xC2) {
            const char *word = NULL;
            if (src[1] == 0xA3) word = "pound";   /* £ */
            else if (src[1] == 0xA2) word = "cent";    /* ¢ */
            else if (src[1] == 0xA5) word = "yen";     /* ¥ */
            if (word) {
                while (*word) *dst++ = *word++;
                src += 2;
                continue;
            }
        }
        if (seqlen == 3 && c == 0xE2 && src[1] == 0x82 && src[2] == 0xAC) {
            const char *word = "euro";  /* € */
            while (*word) *dst++ = *word++;
            src += 3;
            continue;
        }

        /* Em-dash / En-dash → comma attached to word */
        if (seqlen == 3 && c == 0xE2 && src[1] == 0x80 &&
            (src[2] == 0x94 || src[2] == 0x93)) {
            while (dst > out && (*(dst-1) == ' ' || *(dst-1) == '\t'))
                dst--;
            if (dst > out)
                *dst++ = ',';
            src += 3;
            /* Skip trailing punctuation that would end up isolated */
            while (*src == '.' || *src == ',' || *src == '!' ||
                   *src == '?' || *src == ';' || *src == ':') src++;
            while (*src == ' ' || *src == '\t') src++;
            *dst++ = ' ';
            continue;
        }

        *dst++ = ' ';
        src += seqlen;
    }
    *dst = '\0';
    return out;
}

/* Synchronous speak - this is called by the module framework */
void module_speak_sync(const char *data, size_t bytes, SPDMessageType msgtype)
{
    if (eciHandle == NULL_ECI_HAND) {
        module_speak_error();
        return;
    }
    
    stop_requested = 0;
    
    /* Reset audio buffer */
    pthread_mutex_lock(&audio_mutex);
    audio_data.num_samples = 0;
    pthread_mutex_unlock(&audio_mutex);
    
    /* Apply per-utterance overrides from speech-dispatcher */
    eciSetVoiceParam(eciHandle, 0, eciSpeed, current_rate);
    eciSetVoiceParam(eciHandle, 0, eciPitchBaseline, current_pitch);
    eciSetVoiceParam(eciHandle, 0, eciVolume, current_volume);
    
    /* Strip SSML tags */
    char *text = strip_ssml(data, bytes);
    if (!text || !*text) {
        free(text);
        module_speak_error();
        return;
    }

    /* Only sanitize during normal reading — let ViaVoice announce
     * the actual character for CHAR and KEY message types */
    if (msgtype == SPD_MSGTYPE_TEXT || msgtype == SPD_MSGTYPE_SOUND_ICON) {
        char *sanitized = sanitize_for_viavoice(text);
        free(text);
        text = sanitized;
        if (!text || !*text) {
            free(text);
            module_speak_error();
            return;
        }
    }

    DBG("Speaking: %s", text);

    /* Confirm we're ready */
    module_speak_ok();
    
    /* Add text to ECI */
    if (!eciAddText(eciHandle, text)) {
        DBG("eciAddText failed");
        free(text);
        module_report_event_end();
        return;
    }
    free(text);
    
    /* Report that synthesis is beginning */
    module_report_event_begin();
    
    /* Synthesize */
    if (!eciSynthesize(eciHandle)) {
        DBG("eciSynthesize failed");
        module_report_event_end();
        return;
    }
    
    /* Wait for synthesis to complete */
    eciSynchronize(eciHandle);
    
    if (stop_requested) {
        module_report_event_stop();
        return;
    }
    
    /* Send audio to speech-dispatcher server */
    pthread_mutex_lock(&audio_mutex);
    if (audio_data.num_samples > 0) {
        AudioTrack track;
        track.bits = 16;
        track.num_channels = 1;
        track.sample_rate = eci_sample_rate;
        track.num_samples = audio_data.num_samples;
        track.samples = audio_data.samples;
        
        module_tts_output_server(&track, SPD_AUDIO_LE);
    }
    pthread_mutex_unlock(&audio_mutex);
    
    module_report_event_end();
}

/* Asynchronous speak - we use synchronous mode */
int module_speak(char *data, size_t bytes, SPDMessageType msgtype)
{
    (void)data;
    (void)bytes;
    (void)msgtype;
    /* Return -1 to tell framework to use module_speak_sync instead */
    return -1;
}

size_t module_pause(void)
{
    DBG("pause requested");
    stop_requested = 1;
    if (eciHandle != NULL_ECI_HAND) {
        eciStop(eciHandle);
    }
    return 0;
}

int module_stop(void)
{
    DBG("stop requested");
    stop_requested = 1;
    if (eciHandle != NULL_ECI_HAND) {
        eciStop(eciHandle);
    }
    return 0;
}

int module_close(void)
{
    DBG("closing");
    
    /* Free dictionary before deleting ECI handle */
    if (dictHandle != NULL_DICT_HAND && eciHandle != NULL_ECI_HAND) {
        eciDeleteDict(eciHandle, dictHandle);
        dictHandle = NULL_DICT_HAND;
    }
    
    if (eciHandle != NULL_ECI_HAND) {
        eciDelete(eciHandle);
        eciHandle = NULL_ECI_HAND;
    }
    
    if (audio_buffer) {
        free(audio_buffer);
        audio_buffer = NULL;
    }
    
    pthread_mutex_lock(&audio_mutex);
    if (audio_data.samples) {
        free(audio_data.samples);
        audio_data.samples = NULL;
    }
    audio_data.num_samples = 0;
    audio_data.allocated = 0;
    pthread_mutex_unlock(&audio_mutex);
    
    return 0;
}
