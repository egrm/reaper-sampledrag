// SampleDrag - REAPER extension for dragging timeline items to sampler plugins
// macOS ARM64 only. Compiled as Objective-C++.

#define REAPERAPI_IMPLEMENT

#import <Cocoa/Cocoa.h>
#include <sys/stat.h>
#include <reaper_plugin.h>

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

static void (*ShowConsoleMsg)(const char* msg);

#ifdef SAMPLEDRAG_DEBUG
#define SD_LOG(fmt, ...) do { \
    char _sdbuf[4096]; \
    snprintf(_sdbuf, sizeof(_sdbuf), "[SampleDrag] " fmt "\n", ##__VA_ARGS__); \
    if (ShowConsoleMsg) ShowConsoleMsg(_sdbuf); \
} while(0)
#else
#define SD_LOG(fmt, ...) ((void)0)
#endif

// ---------------------------------------------------------------------------
// REAPER API function pointers
// ---------------------------------------------------------------------------
static MediaItem* (*GetSelectedMediaItem)(ReaProject* proj, int selitem);
static MediaItem_Take* (*GetActiveTake)(MediaItem* item);
static PCM_source* (*GetMediaItemTake_Source)(MediaItem_Take* take);
static void (*GetMediaSourceFileName)(PCM_source* source, char* buf, int buf_sz);
static double (*GetMediaSourceLength)(PCM_source* source, bool* lengthIsQNOut);
static double (*GetMediaItemInfo_Value)(MediaItem* item, const char* parmname);
static double (*GetMediaItemTakeInfo_Value)(MediaItem_Take* take, const char* parmname);
static bool (*GetSetMediaItemTakeInfo_String)(MediaItem_Take* take, const char* parmname,
                                              char* newvalue, bool setNewValue);
static void (*GetProjectPathEx)(ReaProject* proj, char* buf, int buf_sz);
static int (*TakeFX_GetCount)(MediaItem_Take* take);
static void (*Main_OnCommand)(int command, int flag);
static int (*plugin_register)(const char* name, void* infostruct);

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------

static HWND s_main_hwnd = nullptr;
static int s_cmdId = 0;
static bool s_armed = false;
static char s_armed_filepath[4096] = {};
static id s_mouse_monitor = nil;
static id s_key_monitor = nil;
static id s_cursor_monitor = nil;

// Forward declarations
static void sampledrag_arm();
static void sampledrag_disarm();
static void sampledrag_install_monitor();
static void sampledrag_do_drag();
static bool sampledrag_render(PCM_source* source, double offset, double length,
                              MediaItem_Take* take);
static bool sampledrag_resolve_and_render();

// ---------------------------------------------------------------------------
// WAV writer
// ---------------------------------------------------------------------------

#pragma pack(push, 1)
struct WavHeader {
    char riff[4] = {'R','I','F','F'};
    uint32_t file_size = 0;
    char wave[4] = {'W','A','V','E'};
    char fmt[4] = {'f','m','t',' '};
    uint32_t fmt_size = 16;
    uint16_t audio_format = 1; // PCM
    uint16_t num_channels = 0;
    uint32_t sample_rate = 0;
    uint32_t byte_rate = 0;
    uint16_t block_align = 0;
    uint16_t bits_per_sample = 0;
    char data_tag[4] = {'d','a','t','a'};
    uint32_t data_size = 0;
};
#pragma pack(pop)

static bool write_wav(const char* path, const double* samples, int num_samples,
                      int nch, int srate, int bps)
{
    FILE* f = fopen(path, "wb");
    if (!f) return false;

    int bytes_per_sample = bps / 8;
    uint32_t data_size = (uint32_t)((int64_t)num_samples * nch * bytes_per_sample);

    WavHeader hdr;
    hdr.num_channels = (uint16_t)nch;
    hdr.sample_rate = (uint32_t)srate;
    hdr.bits_per_sample = (uint16_t)bps;
    hdr.block_align = (uint16_t)(nch * bytes_per_sample);
    hdr.byte_rate = (uint32_t)(srate * nch * bytes_per_sample);
    hdr.data_size = data_size;
    hdr.file_size = 36 + data_size;

    fwrite(&hdr, sizeof(hdr), 1, f);

    for (int i = 0; i < num_samples * nch; i++) {
        double s = samples[i];
        if (s > 1.0) s = 1.0;
        if (s < -1.0) s = -1.0;

        if (bps == 24) {
            int32_t v = (int32_t)(s * 8388607.0);
            uint8_t b[3] = {
                (uint8_t)(v & 0xFF),
                (uint8_t)((v >> 8) & 0xFF),
                (uint8_t)((v >> 16) & 0xFF)
            };
            fwrite(b, 3, 1, f);
        } else if (bps == 16) {
            int16_t v = (int16_t)(s * 32767.0);
            fwrite(&v, 2, 1, f);
        } else {
            float v = (float)s;
            fwrite(&v, 4, 1, f);
        }
    }

    fclose(f);
    return true;
}

// ---------------------------------------------------------------------------
// Filename generation
// ---------------------------------------------------------------------------

static void generate_output_path(char* out, int out_sz, const char* item_name)
{
    char projdir[4096] = {};
    GetProjectPathEx(nullptr, projdir, sizeof(projdir));

    // Sanitize item name
    char safe_name[256] = "item";
    if (item_name && item_name[0]) {
        int j = 0;
        for (int i = 0; item_name[i] && j < 254; i++) {
            char c = item_name[i];
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                (c >= '0' && c <= '9') || c == '-' || c == '_')
                safe_name[j++] = c;
            else if (c == ' ')
                safe_name[j++] = '_';
        }
        safe_name[j] = 0;
        if (!safe_name[0]) strcpy(safe_name, "item");
    }

    // GetProjectPathEx returns the recording path (usually the Media folder)
    char mediadir[4096];
    if (projdir[0] && !strstr(projdir, "/tmp")) {
        strncpy(mediadir, projdir, sizeof(mediadir) - 1);
        mkdir(mediadir, 0755);
    } else {
        const char* tmp = getenv("TMPDIR");
        if (tmp) strncpy(mediadir, tmp, sizeof(mediadir) - 1);
        else strcpy(mediadir, "/tmp");
    }

    for (int n = 1; ; n++) {
        snprintf(out, out_sz, "%s/%s_sd_%d.wav", mediadir, safe_name, n);
        struct stat st;
        if (stat(out, &st) != 0) return;
    }
}

// ---------------------------------------------------------------------------
// Renderer - reads PCM_source and writes cropped WAV
// ---------------------------------------------------------------------------

static bool sampledrag_render(PCM_source* source, double offset, double length,
                              MediaItem_Take* take)
{
    int nch = source->GetNumChannels();
    int srate = (int)source->GetSampleRate();
    int bps = source->GetBitsPerSample();
    if (bps == 0) bps = 24;
    if (nch < 1 || srate < 1) return false;

    int total_samples = (int)(length * srate + 0.5);
    if (total_samples < 1) return false;

    double* buf = (double*)malloc((size_t)total_samples * nch * sizeof(double));
    if (!buf) return false;
    memset(buf, 0, (size_t)total_samples * nch * sizeof(double));

    const int block_size = 65536;
    int samples_read = 0;
    double time = offset;

    while (samples_read < total_samples) {
        int to_read = total_samples - samples_read;
        if (to_read > block_size) to_read = block_size;

        PCM_source_transfer_t xfer = {};
        xfer.time_s = time;
        xfer.samplerate = srate;
        xfer.nch = nch;
        xfer.length = to_read;
        xfer.samples = buf + ((size_t)samples_read * nch);

        source->GetSamples(&xfer);
        if (xfer.samples_out < 1) break;

        samples_read += xfer.samples_out;
        time += (double)xfer.samples_out / srate;
    }

    char item_name[256] = {};
    GetSetMediaItemTakeInfo_String(take, "P_NAME", item_name, false);

    char outpath[4096] = {};
    generate_output_path(outpath, sizeof(outpath), item_name);

    bool ok = write_wav(outpath, buf, samples_read, nch, srate, bps);
    free(buf);

    if (ok) strncpy(s_armed_filepath, outpath, sizeof(s_armed_filepath) - 1);
    return ok;
}

// ---------------------------------------------------------------------------
// Disarm - clean up monitors and state
// ---------------------------------------------------------------------------

static void sampledrag_disarm()
{
    SD_LOG("disarm: was_armed=%d", s_armed);
    bool was_armed = s_armed;
    s_armed = false;
    s_armed_filepath[0] = 0;

    if (s_mouse_monitor) {
        [NSEvent removeMonitor:s_mouse_monitor];
        s_mouse_monitor = nil;
    }
    if (s_key_monitor) {
        [NSEvent removeMonitor:s_key_monitor];
        s_key_monitor = nil;
    }
    if (s_cursor_monitor) {
        [NSEvent removeMonitor:s_cursor_monitor];
        s_cursor_monitor = nil;
    }
    if (was_armed) [[NSCursor arrowCursor] set];
}

// ---------------------------------------------------------------------------
// Drag initiation
// ---------------------------------------------------------------------------

static void sampledrag_do_drag()
{
    if (!s_armed || !s_armed_filepath[0]) return;
    SD_LOG("do_drag: %s", s_armed_filepath);

    const char* files[] = { s_armed_filepath };
    RECT r = { 0, 0, 32, 32 };

    NSPoint mouse = [NSEvent mouseLocation];
    r.left = (int)mouse.x - 16;
    r.top = (int)mouse.y - 16;
    r.right = r.left + 32;
    r.bottom = r.top + 32;

    SWELL_InitiateDragDropOfFileList(s_main_hwnd, &r, files, 1, nullptr);
}

// ---------------------------------------------------------------------------
// Install NSEvent monitors (armed state)
// ---------------------------------------------------------------------------

static void sampledrag_install_monitor()
{
    if (s_mouse_monitor) {
        [NSEvent removeMonitor:s_mouse_monitor];
        s_mouse_monitor = nil;
    }
    if (s_key_monitor) {
        [NSEvent removeMonitor:s_key_monitor];
        s_key_monitor = nil;
    }
    if (s_cursor_monitor) {
        [NSEvent removeMonitor:s_cursor_monitor];
        s_cursor_monitor = nil;
    }

    // Keep crosshair cursor while armed. We dispatch_async so our set runs
    // AFTER REAPER's own cursor update in the same run loop iteration.
    s_cursor_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved
        handler:^NSEvent*(NSEvent* event) {
            if (s_armed) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (s_armed) [[NSCursor crosshairCursor] set];
                });
            }
            return event;
        }];

    s_mouse_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
        handler:^NSEvent*(NSEvent* event) {
            if (!s_armed) return event;

            SD_LOG("monitor: mouse-down intercepted");
            if (sampledrag_resolve_and_render()) {
                sampledrag_do_drag();
                sampledrag_disarm();
                return nil;
            }
            SD_LOG("monitor: no item under cursor, disarming");
            sampledrag_disarm();
            return event;
        }];

    s_key_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
        handler:^NSEvent*(NSEvent* event) {
            if (s_armed && event.keyCode == 53) {
                sampledrag_disarm();
                return nil;
            }
            return event;
        }];
}

// ---------------------------------------------------------------------------
// Resolve item under cursor, render if needed, populate s_armed_filepath
// ---------------------------------------------------------------------------

static bool sampledrag_resolve_and_render()
{
    Main_OnCommand(40528, 0); // Select item under mouse cursor

    MediaItem* item = GetSelectedMediaItem(nullptr, 0);
    if (!item) { SD_LOG("resolve: no item under cursor"); return false; }
    SD_LOG("resolve: item=%p", item);

    MediaItem_Take* take = GetActiveTake(item);
    if (!take) { SD_LOG("resolve: no active take"); return false; }

    PCM_source* source = GetMediaItemTake_Source(take);
    if (!source) { SD_LOG("resolve: no source"); return false; }

    char srcfile[4096] = {};
    GetMediaSourceFileName(source, srcfile, sizeof(srcfile));
    if (!srcfile[0]) { SD_LOG("resolve: no filename"); return false; }
    SD_LOG("resolve: src=%s", srcfile);

    double soffs = GetMediaItemTakeInfo_Value(take, "D_STARTOFFS");
    double item_len = GetMediaItemInfo_Value(item, "D_LENGTH");
    bool lengthIsQN = false;
    double src_len = GetMediaSourceLength(source, &lengthIsQN);
    int takefx_count = TakeFX_GetCount(take);

    SD_LOG("resolve: soffs=%.4f len=%.4f srclen=%.4f takeFX=%d",
           soffs, item_len, src_len, takefx_count);

    if (takefx_count > 0) {
        SD_LOG("resolve: rendering with %d take FX", takefx_count);
        Main_OnCommand(40209, 0);

        MediaItem_Take* fxTake = GetActiveTake(item);
        if (!fxTake) { SD_LOG("resolve: FX render produced no take"); return false; }

        PCM_source* fxSource = GetMediaItemTake_Source(fxTake);
        if (!fxSource) { SD_LOG("resolve: FX take has no source"); Main_OnCommand(40029, 0); return false; }

        char fxFile[4096] = {};
        GetMediaSourceFileName(fxSource, fxFile, sizeof(fxFile));
        if (!fxFile[0]) { SD_LOG("resolve: FX file has no name"); Main_OnCommand(40029, 0); return false; }

        Main_OnCommand(40029, 0); // undo - restores original take, file stays on disk

        // Rename REAPER's rendered file to our naming convention
        char item_name[256] = {};
        GetSetMediaItemTakeInfo_String(take, "P_NAME", item_name, false);
        char outpath[4096] = {};
        generate_output_path(outpath, sizeof(outpath), item_name);
        rename(fxFile, outpath);
        strncpy(s_armed_filepath, outpath, sizeof(s_armed_filepath) - 1);
        SD_LOG("resolve: FX rendered, renamed to %s", s_armed_filepath);
    } else {
        bool needs_render = (soffs > 0.01 || (src_len - item_len) > 0.01);
        SD_LOG("resolve: needs_render=%d", needs_render);

        if (needs_render) {
            if (!sampledrag_render(source, soffs, item_len, take)) {
                SD_LOG("resolve: render failed");
                return false;
            }
            SD_LOG("resolve: rendered to %s", s_armed_filepath);
        } else {
            strncpy(s_armed_filepath, srcfile, sizeof(s_armed_filepath) - 1);
            SD_LOG("resolve: using raw source");
        }
    }

    return true;
}

// ---------------------------------------------------------------------------
// Arm - enters armed cursor mode
// ---------------------------------------------------------------------------

static void sampledrag_arm()
{
    if (s_armed) {
        SD_LOG("arm: toggling off");
        sampledrag_disarm();
        return;
    }

    s_armed = true;
    sampledrag_install_monitor();
    [[NSCursor crosshairCursor] set];
    SD_LOG("ARMED - click an item to drag, Escape to cancel");
}

// ---------------------------------------------------------------------------
// Hook command callback
// ---------------------------------------------------------------------------

static bool hookCommandProc(int command, int flag)
{
    if (command == s_cmdId) {
        sampledrag_arm();
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

extern "C" {

REAPER_PLUGIN_DLL_EXPORT int REAPER_PLUGIN_ENTRYPOINT(
    REAPER_PLUGIN_HINSTANCE hInstance, reaper_plugin_info_t *rec)
{
    if (!rec) {
        sampledrag_disarm();
        return 0;
    }

    if (rec->caller_version != REAPER_PLUGIN_VERSION || !rec->GetFunc)
        return 0;

    #define IMPAPI(x) if (!((*((void **)&(x)) = (void *)rec->GetFunc(#x)))) errcnt++

    int errcnt = 0;
    IMPAPI(ShowConsoleMsg);
    IMPAPI(GetSelectedMediaItem);
    IMPAPI(GetActiveTake);
    IMPAPI(GetMediaItemTake_Source);
    IMPAPI(GetMediaSourceFileName);
    IMPAPI(GetMediaSourceLength);
    IMPAPI(GetMediaItemInfo_Value);
    IMPAPI(GetMediaItemTakeInfo_Value);
    IMPAPI(GetSetMediaItemTakeInfo_String);
    IMPAPI(GetProjectPathEx);
    IMPAPI(TakeFX_GetCount);
    IMPAPI(Main_OnCommand);

    *((void **)&plugin_register) = (void *)rec->GetFunc("plugin_register");

    if (errcnt || !plugin_register) return 0;

    s_main_hwnd = rec->hwnd_main;

    s_cmdId = plugin_register("command_id", (void*)"SAMPLEDRAG_ARM");
    if (s_cmdId) {
        static gaccel_register_t accel = { { 0, 0, 0 }, "SampleDrag: Arm drag from timeline" };
        accel.accel.cmd = s_cmdId;
        plugin_register("gaccel", &accel);
    }

    rec->Register("hookcommand", (void*)hookCommandProc);
    return 1;
}

} // extern "C"
