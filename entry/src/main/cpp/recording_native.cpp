#include <napi/native_api.h>
#include <multimedia/player_framework/native_avscreen_capture.h>
#include <multimedia/player_framework/native_avcodec_videoencoder.h>
#include <multimedia/player_framework/native_avcodec_audiocodec.h>
#include <multimedia/player_framework/native_avdemuxer.h>
#include <multimedia/player_framework/native_avmuxer.h>
#include <multimedia/player_framework/native_avsource.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <native_window/external_window.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <fcntl.h>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <time.h>
#include <vector>
#include <sys/stat.h>
#include <unistd.h>
#include "recording_audio_math.h"
#include "recording_echo_filter.h"

namespace {
constexpr int RATE = 48000;
constexpr int CHANNELS = 2;
constexpr int FRAME_BYTES = CHANNELS * sizeof(int16_t);
constexpr int VIDEO_FRAME_RATE = 30;
constexpr int64_t VIDEO_BITRATE = 8000000;
constexpr size_t MAX_PCM_QUEUE_BYTES = RATE * FRAME_BYTES * 2;
constexpr size_t MAX_VIDEO_QUEUE = 32;
using namespace std::chrono_literals;

void Check(bool valid, const char *message)
{
    if (!valid) throw std::runtime_error(message);
}
int64_t MonotonicNowUs()
{
    timespec time{};
    Check(clock_gettime(CLOCK_MONOTONIC, &time) == 0, "无法读取录制单调时钟");
    return static_cast<int64_t>(time.tv_sec) * 1000000 + time.tv_nsec / 1000;
}
void AvCheck(OH_AVErrCode result, const char *message) { Check(result == AV_ERR_OK, message); }
void WriteAll(int fd, const void *data, size_t size)
{
    auto bytes = static_cast<const uint8_t *>(data);
    while (size > 0) {
        ssize_t written = write(fd, bytes, size);
        Check(written > 0, "录制文件写入失败，请检查存储空间");
        size -= written;
        bytes += written;
    }
}
struct Fd {
    int value = -1;
    explicit Fd(const std::string &path, bool output = false)
        : value(open(path.c_str(), output ? O_CREAT | O_RDWR | O_TRUNC : O_RDONLY, 0600))
    { Check(value >= 0, "无法打开录制音轨文件"); }
    ~Fd() { if (value >= 0) close(value); }
};
struct Format {
    OH_AVFormat *value = nullptr;
    explicit Format(OH_AVFormat *format) : value(format) { Check(value != nullptr, "无法读取媒体格式"); }
    ~Format() { OH_AVFormat_Destroy(value); }
};
struct Buffer {
    OH_AVBuffer *value = nullptr;
    explicit Buffer(int capacity) : value(OH_AVBuffer_Create(capacity)) { Check(value != nullptr, "媒体缓冲区不足"); }
    ~Buffer() { OH_AVBuffer_Destroy(value); }
};
struct CodecBuffer { uint32_t index; OH_AVBuffer *buffer; };
struct PcmChunk { bool microphone; int64_t timestampNs; std::vector<uint8_t> bytes; };
struct TrackWriter {
    int fd = -1;
    int64_t firstTimestampNs = -1;
    onebeat_recording::ContiguousPcmTimeline timeline;
    void Append(const PcmChunk &chunk)
    {
        Check(!chunk.bytes.empty() && chunk.bytes.size() % FRAME_BYTES == 0,
            "采集音频帧格式无效");
        const int64_t chunkFrames = chunk.bytes.size() / FRAME_BYTES;
        // Copied AVScreenCapture payloads are already ordered PCM chunks. Their
        // hardware timestamps can quantize or jitter at callback boundaries;
        // using that jitter to edit every chunk creates periodic zero/skip seams.
        Check(timeline.Append(chunk.timestampNs, chunkFrames), "采集时间戳无效，录制已结束");
        WriteAll(fd, chunk.bytes.data(), chunk.bytes.size());
        firstTimestampNs = timeline.FirstTimestampNs();
    }
};

class CaptureSession {
public:
    std::string videoPath, innerPath, micPath;
    int width = 720, height = 1560;
    std::atomic<int> state{-1};
    std::atomic<float> peak{0};
    std::atomic<bool> cancelled{false};
    std::atomic<bool> acceptingPcm{false};
    std::atomic<bool> writerDone{false};
    std::atomic<bool> videoClosing{false};
    int64_t firstVideoPtsUs = -1, lastVideoPtsUs = 0;
    int64_t micOffsetUs = 0, innerOffsetUs = 0, durationMs = 0;
    int64_t micFirstPtsUs = -1, innerFirstPtsUs = -1;
    int videoTimestampDivisor = 0;
    bool syncValid = true;

    std::string Error()
    {
        std::lock_guard<std::mutex> lock(statusMutex);
        return error;
    }
    void Fail(const std::string &message)
    {
        { std::lock_guard<std::mutex> lock(statusMutex); if (error.empty()) error = message; }
        state.store(3);
        statusCv.notify_all();
    }
    void Cancel() { cancelled.store(true); statusCv.notify_all(); }

    void Start()
    {
        {
            std::lock_guard<std::mutex> lock(controlMutex);
            if (cancelled.load()) throw std::runtime_error("已取消录制");
            videoPtsNormalizer.Reset(MonotonicNowUs());
            videoFile = std::make_unique<Fd>(videoPath, true);
            innerFile = std::make_unique<Fd>(innerPath, true);
            micFile = std::make_unique<Fd>(micPath, true);
            innerWriter.fd = innerFile->value;
            micWriter.fd = micFile->value;
            muxer = OH_AVMuxer_Create(videoFile->value, AV_OUTPUT_FORMAT_MPEG_4);
            Check(muxer != nullptr, "无法创建录制视频");
            encoder = OH_VideoEncoder_CreateByMime("video/avc");
            Check(encoder != nullptr, "设备不支持 H.264 录制");
            OH_AVCodecCallback callbacks{CodecError, VideoFormat, NoInput, VideoOutput};
            AvCheck(OH_VideoEncoder_RegisterCallback(encoder, callbacks, this), "无法注册视频编码器");
            Format format(OH_AVFormat_CreateVideoFormat("video/avc", width, height));
            OH_AVFormat_SetDoubleValue(format.value, OH_MD_KEY_FRAME_RATE, VIDEO_FRAME_RATE);
            OH_AVFormat_SetLongValue(format.value, OH_MD_KEY_BITRATE, VIDEO_BITRATE);
            OH_AVFormat_SetIntValue(format.value, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_SURFACE_FORMAT);
            AvCheck(OH_VideoEncoder_Configure(encoder, format.value), "视频编码配置失败");
            AvCheck(OH_VideoEncoder_GetSurface(encoder, &window), "无法连接录屏画面");
            AvCheck(OH_VideoEncoder_Prepare(encoder), "视频编码准备失败");
            AvCheck(OH_AVMuxer_AddTrack(muxer, &videoTrack, format.value), "视频轨道创建失败");
            AvCheck(OH_AVMuxer_Start(muxer), "视频封装启动失败");
            muxerStarted = true;
            acceptingPcm.store(true);
            acceptingVideo.store(true);
            pcmThread = std::thread([this] { PcmLoop(); });
            videoThread = std::thread([this] { VideoLoop(); });
            AvCheck(OH_VideoEncoder_Start(encoder), "视频编码启动失败");
            videoEncoderStarted.store(true);
            capture = OH_AVScreenCapture_Create();
            Check(capture != nullptr, "系统录屏服务不可用");
            Check(OH_AVScreenCapture_SetStateCallback(capture, StateChanged, this) == AV_SCREEN_CAPTURE_ERR_OK,
                "无法监听录屏授权状态");
            Check(OH_AVScreenCapture_SetErrorCallback(capture, CaptureError, this) == AV_SCREEN_CAPTURE_ERR_OK,
                "无法监听录屏服务错误");
            Check(OH_AVScreenCapture_SetDataCallback(capture, PcmAvailable, this) == AV_SCREEN_CAPTURE_ERR_OK,
                "无法连接独立声音音轨");
            Check(OH_AVScreenCapture_SetMicrophoneEnabled(capture, true) == AV_SCREEN_CAPTURE_ERR_OK,
                "无法启用录制麦克风");
            OH_AVScreenCaptureConfig config{};
            config.captureMode = OH_CAPTURE_HOME_SCREEN;
            config.dataType = OH_ORIGINAL_STREAM;
            config.audioInfo.micCapInfo = {RATE, CHANNELS, OH_MIC};
            config.audioInfo.innerCapInfo = {RATE, CHANNELS, OH_APP_PLAYBACK};
            config.videoInfo.videoCapInfo.videoFrameWidth = width;
            config.videoInfo.videoCapInfo.videoFrameHeight = height;
            config.videoInfo.videoCapInfo.videoSource = OH_VIDEO_SOURCE_SURFACE_RGBA;
            Check(OH_AVScreenCapture_Init(capture, config) == AV_SCREEN_CAPTURE_ERR_OK, "录屏参数初始化失败");
            auto *filter = OH_AVScreenCapture_CreateContentFilter();
            Check(filter != nullptr, "无法创建录制声音过滤器");
            auto filterResult = OH_AVScreenCapture_ContentFilter_AddAudioContent(filter,
                OH_SCREEN_CAPTURE_NOTIFICATION_AUDIO);
            if (filterResult == AV_SCREEN_CAPTURE_ERR_OK)
                filterResult = OH_AVScreenCapture_ExcludeContent(capture, filter);
            OH_AVScreenCapture_ReleaseContentFilter(filter);
            Check(filterResult == AV_SCREEN_CAPTURE_ERR_OK, "无法过滤录制中的通知提示音");
            Check(OH_AVScreenCapture_StartScreenCaptureWithSurface(capture, window) == AV_SCREEN_CAPTURE_ERR_OK,
                "无法开始系统录屏");
        }
        // Start returns before consent. Native state callback, rather than a JS
        // callback delivery time, controls the recording lifecycle.
        std::unique_lock<std::mutex> lock(statusMutex);
        statusCv.wait(lock, [this] { return state.load() != -1 || cancelled.load(); });
        Check(!cancelled.load() && state.load() == 0, error.empty() ? "已取消录制" : error.c_str());
    }

    void Stop()
    {
        Cancel();
        std::lock_guard<std::mutex> lock(controlMutex);
        if (stopped) return;
        stopped = true;
        if (capture != nullptr) {
            OH_AVScreenCapture_StopScreenCapture(capture);
            OH_AVScreenCapture_Release(capture);
            capture = nullptr;
        }
        acceptingPcm.store(false);
        pcmCv.notify_all();
        if (pcmThread.joinable()) pcmThread.join();
        if (encoder != nullptr && videoEncoderStarted.load()) OH_VideoEncoder_NotifyEndOfStream(encoder);
        videoClosing.store(true);
        videoCv.notify_all();
        if (videoThread.joinable()) videoThread.join();
        if (encoder != nullptr) {
            OH_VideoEncoder_Stop(encoder);
            OH_VideoEncoder_Destroy(encoder);
            encoder = nullptr;
        }
        if (muxer != nullptr) {
            if (muxerStarted) OH_AVMuxer_Stop(muxer);
            OH_AVMuxer_Destroy(muxer);
            muxer = nullptr;
        }
        if (window != nullptr) { OH_NativeWindow_DestroyNativeWindow(window); window = nullptr; }
        videoFile.reset(); innerFile.reset(); micFile.reset();
        if (firstVideoPtsUs >= 0) {
            durationMs = std::max<int64_t>(1, (lastVideoPtsUs - firstVideoPtsUs + 33333) / 1000);
            if (micWriter.firstTimestampNs >= 0) {
                micFirstPtsUs = micWriter.firstTimestampNs / 1000;
                micOffsetUs = micFirstPtsUs - firstVideoPtsUs;
            }
            if (innerWriter.firstTimestampNs >= 0) {
                innerFirstPtsUs = innerWriter.firstTimestampNs / 1000;
                innerOffsetUs = innerFirstPtsUs - firstVideoPtsUs;
            }
            // VideoLoop has normalized the Surface's ns/us contract before
            // muxing. PCM stays in monotonic ns; every track shares the same
            // real video-first origin, retaining its measured start offset.
            if (std::abs(micOffsetUs) > 10000000 || std::abs(innerOffsetUs) > 10000000) {
                syncValid = false;
                Fail("设备录屏时间戳不兼容，无法保证三路同步");
            }
        }
    }
    ~CaptureSession() { Stop(); }

private:
    OH_AVScreenCapture *capture = nullptr;
    OH_AVCodec *encoder = nullptr;
    OH_AVMuxer *muxer = nullptr;
    OHNativeWindow *window = nullptr;
    int32_t videoTrack = -1;
    bool muxerStarted = false, stopped = false;
    std::unique_ptr<Fd> videoFile, innerFile, micFile;
    TrackWriter innerWriter, micWriter;
    onebeat_recording::SurfacePtsNormalizer videoPtsNormalizer;
    std::thread pcmThread, videoThread;
    std::atomic<bool> acceptingVideo{false}, videoEncoderStarted{false};
    std::mutex controlMutex, statusMutex, pcmMutex, videoMutex;
    std::condition_variable statusCv, pcmCv, videoCv;
    std::string error;
    std::deque<PcmChunk> pcmQueue;
    size_t queuedPcmBytes = 0;
    std::deque<CodecBuffer> videoQueue;

    static void StateChanged(OH_AVScreenCapture *, OH_AVScreenCaptureStateCode code, void *data)
    {
        auto *self = static_cast<CaptureSession *>(data);
        self->state.store(static_cast<int>(code));
        self->statusCv.notify_all();
    }
    static void CaptureError(OH_AVScreenCapture *, int32_t, void *data)
    { static_cast<CaptureSession *>(data)->Fail("系统录屏采集异常"); }
    static void CodecError(OH_AVCodec *, int32_t, void *data)
    { static_cast<CaptureSession *>(data)->Fail("视频编码异常"); }
    static void VideoFormat(OH_AVCodec *, OH_AVFormat *, void *) {}
    static void NoInput(OH_AVCodec *, uint32_t, OH_AVBuffer *, void *) {}
    static void VideoOutput(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *data)
    {
        auto *self = static_cast<CaptureSession *>(data);
        bool queued = false;
        try {
            bool overloaded = false;
            {
                std::lock_guard<std::mutex> lock(self->videoMutex);
                if (self->acceptingVideo.load()) {
                    overloaded = self->videoQueue.size() >= MAX_VIDEO_QUEUE;
                    if (!overloaded) {
                        self->videoQueue.push_back({index, buffer});
                        queued = true;
                    }
                }
            }
            if (overloaded) {
                self->Fail("设备编码负载过高，录制已结束");
            }
        } catch (...) {
            // A C callback must never unwind through the platform codec ABI,
            // including allocation failure while growing the bounded deque.
            try { self->Fail("录制缓冲区不足"); }
            catch (...) { self->state.store(3); self->statusCv.notify_all(); }
        }
        // Returning a codec buffer can synchronously make another callback
        // runnable. Never call it while holding the queue mutex.
        if (!queued) OH_VideoEncoder_FreeOutputBuffer(codec, index);
        else self->videoCv.notify_one();
    }
    static void PcmAvailable(OH_AVScreenCapture *, OH_AVBuffer *buffer,
        OH_AVScreenCaptureBufferType type, int64_t timestampNs, void *data)
    {
        auto *self = static_cast<CaptureSession *>(data);
        if (!self->acceptingPcm.load() || type == OH_SCREEN_CAPTURE_BUFFERTYPE_VIDEO) return;
        const bool isMic = type == OH_SCREEN_CAPTURE_BUFFERTYPE_AUDIO_MIC;
        const bool isInner = type == OH_SCREEN_CAPTURE_BUFFERTYPE_AUDIO_INNER;
        // Only the documented inner/mic buffer types may enter a stem. Other
        // audio buffers have been observed on some builds and must not be
        // folded into inner playback or the export sounds doubled/metallic.
        if (!isMic && !isInner) return;
        auto *address = OH_AVBuffer_GetAddr(buffer);
        int capacity = OH_AVBuffer_GetCapacity(buffer);
        // AVScreenCapture wraps each audio callback in an exact-size raw PCM
        // allocation. This callback path does not define codec attrs as a PCM
        // subrange, so using an optional attr offset/size can corrupt both stems.
        if (address == nullptr || capacity <= 0) return;
        if (capacity % FRAME_BYTES != 0) {
            self->Fail("系统返回了不完整的录制音频帧");
            return;
        }
        const int size = capacity;
        try {
            std::lock_guard<std::mutex> lock(self->pcmMutex);
            if (self->queuedPcmBytes + size > MAX_PCM_QUEUE_BYTES) {
                self->Fail("存储写入跟不上采集，录制已结束");
                return;
            }
            // The system frees this memory on callback return. Copy into a
            // bounded queue; no filesystem I/O, encoding, or JS callback here.
            PcmChunk chunk{isMic, timestampNs, {}};
            chunk.bytes.assign(address, address + size);
            self->queuedPcmBytes += size;
            self->pcmQueue.push_back(std::move(chunk));
        } catch (...) { self->Fail("录制缓冲区不足"); }
        self->pcmCv.notify_one();
    }
    void PcmLoop()
    {
        try {
            for (;;) {
                PcmChunk chunk;
                {
                    std::unique_lock<std::mutex> lock(pcmMutex);
                    pcmCv.wait(lock, [this] { return !acceptingPcm.load() || !pcmQueue.empty(); });
                    if (pcmQueue.empty()) break;
                    chunk = std::move(pcmQueue.front()); pcmQueue.pop_front();
                    queuedPcmBytes -= chunk.bytes.size();
                }
                if (chunk.microphone) {
                    const int16_t *samples = reinterpret_cast<const int16_t *>(chunk.bytes.data());
                    int maximum = 0;
                    for (size_t i = 0; i < chunk.bytes.size() / sizeof(int16_t); i++)
                        maximum = std::max(maximum, std::abs(static_cast<int>(samples[i])));
                    float measured = static_cast<float>(maximum) / 32768.0f;
                    float previous = peak.load();
                    while (previous < measured && !peak.compare_exchange_weak(previous, measured)) {}
                }
                (chunk.microphone ? micWriter : innerWriter).Append(chunk);
            }
        } catch (const std::exception &err) { Fail(err.what()); }
        writerDone.store(true);
    }
    void VideoLoop()
    {
        try {
            bool draining = false;
            std::chrono::steady_clock::time_point drainDeadline;
            for (;;) {
                CodecBuffer item{};
                {
                    std::unique_lock<std::mutex> lock(videoMutex);
                    videoCv.wait(lock, [this] { return videoClosing.load() || !videoQueue.empty(); });
                    if (videoClosing.load()) {
                        if (!videoEncoderStarted.load()) break;
                        if (!draining) {
                            draining = true;
                            drainDeadline = std::chrono::steady_clock::now() + 2s;
                        }
                        // Keep valid tail frames until EOS, but a failed or
                        // stalled encoder must not hold Stop's join forever.
                        Check(std::chrono::steady_clock::now() < drainDeadline,
                            "视频编码收尾超时，已保留可用画面");
                        Check(videoCv.wait_until(lock, drainDeadline, [this] { return !videoQueue.empty(); }),
                            "视频编码收尾超时，已保留可用画面");
                    }
                    item = videoQueue.front(); videoQueue.pop_front();
                }
                OH_AVCodecBufferAttr attr{};
                OH_AVBuffer_GetBufferAttr(item.buffer, &attr);
                bool eos = (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0;
                if (attr.size > 0) {
                    if (!(attr.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA)) {
                        int64_t normalizedUs = 0;
                        if (!videoPtsNormalizer.Normalize(attr.pts, MonotonicNowUs(), normalizedUs)) {
                            syncValid = false;
                            OH_VideoEncoder_FreeOutputBuffer(encoder, item.index);
                            throw std::runtime_error("设备录屏时间戳无法映射到采集时钟，原始音轨已保留");
                        }
                        videoTimestampDivisor = videoPtsNormalizer.Divisor();
                        attr.pts = normalizedUs;
                        if (firstVideoPtsUs < 0) firstVideoPtsUs = attr.pts;
                        lastVideoPtsUs = attr.pts;
                        attr.pts -= firstVideoPtsUs;
                    } else attr.pts = 0;
                    OH_AVBuffer_SetBufferAttr(item.buffer, &attr);
                    OH_AVErrCode result = OH_AVMuxer_WriteSampleBuffer(muxer, videoTrack, item.buffer);
                    OH_VideoEncoder_FreeOutputBuffer(encoder, item.index);
                    AvCheck(result, "视频文件写入失败");
                } else OH_VideoEncoder_FreeOutputBuffer(encoder, item.index);
                if (eos) break;
            }
        } catch (const std::exception &err) { Fail(err.what()); }
        // After EOS/error/partial startup, no callback may add another borrowed
        // output buffer. Drain queued ownership before Stop destroys the codec.
        acceptingVideo.store(false);
        for (;;) {
            CodecBuffer item{};
            {
                std::lock_guard<std::mutex> lock(videoMutex);
                if (videoQueue.empty()) break;
                item = videoQueue.front(); videoQueue.pop_front();
            }
            OH_VideoEncoder_FreeOutputBuffer(encoder, item.index);
        }
    }
};

struct MixOptions {
    std::string sourcePath, innerPath, micPath, outputPath, processedMicPath;
    int64_t durationMs = 0, micOffsetUs = 0, innerOffsetUs = 0, micShiftUs = 0;
    int64_t autoMicShiftUs = 0;
    bool autoMicShiftKnown = false;
    bool autoMicShiftReliable = false;
    double autoMicShiftConfidence = 0;
    double gain = 1;
    double speakerBleedCancel = 0;
};
class AudioEncoderQueue {
public:
    OH_AVCodec *codec = nullptr;
    std::mutex mutex;
    std::condition_variable cv;
    std::deque<CodecBuffer> inputs, outputs;
    bool error = false;
    static void Error(OH_AVCodec *, int32_t, void *data)
    { auto *self = static_cast<AudioEncoderQueue *>(data); std::lock_guard<std::mutex> lock(self->mutex);
      self->error = true; self->cv.notify_all(); }
    static void FormatChanged(OH_AVCodec *, OH_AVFormat *, void *) {}
    static void Input(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *data)
    {
        auto *self = static_cast<AudioEncoderQueue *>(data);
        try {
            std::lock_guard<std::mutex> lock(self->mutex);
            self->inputs.push_back({index, buffer});
            self->cv.notify_all();
        } catch (...) { Error(codec, 0, data); }
    }
    static void Output(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *data)
    {
        auto *self = static_cast<AudioEncoderQueue *>(data);
        try {
            std::lock_guard<std::mutex> lock(self->mutex);
            self->outputs.push_back({index, buffer});
            self->cv.notify_all();
        } catch (...) {
            Error(codec, 0, data);
            OH_AudioCodec_FreeOutputBuffer(codec, index);
        }
    }
    ~AudioEncoderQueue() { if (codec != nullptr) { OH_AudioCodec_Stop(codec); OH_AudioCodec_Destroy(codec); } }
};
void ReadAligned(int fd, int64_t outputFrame, int64_t offsetUs, int count, std::vector<int16_t> &samples)
{
    samples.assign(count * CHANNELS, 0);
    int64_t sourceFrame = onebeat_recording::AlignedSourceFrame(outputFrame, offsetUs);
    int leading = static_cast<int>(std::min<int64_t>(count, std::max<int64_t>(0, -sourceFrame)));
    int remaining = count - leading;
    if (remaining <= 0) return;
    ssize_t size = pread(fd, samples.data() + leading * CHANNELS, remaining * FRAME_BYTES,
        std::max<int64_t>(0, sourceFrame) * FRAME_BYTES);
    Check(size >= 0, "读取原始声音失败");
}
void ReadAlignedProcessedMic(int fd, int64_t outputFrame, int64_t offsetUs, int count,
    std::vector<float> &samples)
{
    constexpr int PROCESSED_FRAME_BYTES = CHANNELS * sizeof(float);
    samples.assign(count * CHANNELS, 0);
    int64_t sourceFrame = onebeat_recording::AlignedSourceFrame(outputFrame, offsetUs);
    int leading = static_cast<int>(std::min<int64_t>(count, std::max<int64_t>(0, -sourceFrame)));
    int remaining = count - leading;
    if (remaining <= 0) return;
    uint8_t *target = reinterpret_cast<uint8_t *>(samples.data() + leading * CHANNELS);
    size_t requested = static_cast<size_t>(remaining) * PROCESSED_FRAME_BYTES;
    int64_t position = std::max<int64_t>(0, sourceFrame) * PROCESSED_FRAME_BYTES;
    while (requested > 0) {
        ssize_t size = pread(fd, target, requested, position);
        Check(size >= 0, "读取净化麦克风音轨失败");
        if (size == 0) break;
        requested -= static_cast<size_t>(size);
        target += size;
        position += size;
    }
}
struct EchoModelHistory {
    onebeat_recording::StereoEchoFirEstimate reliable{};
    std::array<int64_t, CHANNELS> anchor{{-1, -1}};
};
struct ProcessedMicInfo {
    int64_t autoMicShiftUs = 0;
    double confidence = 0;
    bool known = false;
    bool reliable = false;
};
void CollectAlignmentSamples(const onebeat_recording::StereoEchoFirEstimate &estimate,
    std::vector<onebeat_recording::EchoAlignmentSample> &samples)
{
    for (const auto &channel : estimate.channels) {
        if (!channel.enabled || channel.revalidated || channel.validationReduction < 0.12 ||
            channel.validationCorrelation < 0.60 || std::abs(channel.delayFrames) > 1440) continue;
        const double weight = channel.validationReduction *
            channel.validationCorrelation * channel.validationCorrelation;
        if (std::isfinite(weight) && weight > 0)
            samples.push_back({channel.delayFrames, weight});
    }
}
onebeat_recording::StereoEchoFirEstimate EstimateEchoAt(int innerFd, int micFd,
    int64_t innerOffsetUs, int64_t micOffsetUs, int64_t anchorFrame, int64_t totalFrames,
    double maximumGain, EchoModelHistory &history)
{
    constexpr int PROBE_FRAMES = RATE * 8 / 5;
    const int64_t lastStart = std::max<int64_t>(0, totalFrames - PROBE_FRAMES);
    const int64_t start = std::clamp<int64_t>(anchorFrame - PROBE_FRAMES / 2, 0, lastStart);
    const int count = static_cast<int>(std::min<int64_t>(PROBE_FRAMES, totalFrames - start));
    if (count < 2400) return {};
    std::vector<int16_t> inner, microphone;
    ReadAligned(innerFd, start, innerOffsetUs, count, inner);
    ReadAligned(micFd, start, micOffsetUs, count, microphone);
    auto estimate = onebeat_recording::EstimateStereoEchoFir(inner.data(), microphone.data(), count,
        14400, maximumGain);
    for (int channel = 0; channel < CHANNELS; ++channel) {
        if (estimate.channels[channel].enabled) {
            history.reliable.channels[channel] = estimate.channels[channel];
            history.anchor[channel] = anchorFrame;
        } else if (history.anchor[channel] >= 0 && anchorFrame - history.anchor[channel] <= RATE * 8) {
            // Loud near-end audio can hide an unchanged echo path from a new
            // 256-dimensional fit. Revalidate only the last reliable shape's
            // scalar gain on this window; a fallback never renews its 8 s life.
            estimate.channels[channel] = onebeat_recording::RevalidateEchoFir(history.reliable.channels[channel],
                inner.data(), microphone.data(), count, channel);
        }
    }
    return estimate;
}

/**
 * Echo fitting depends only on immutable capture stems and their measured offsets.
 * Persist its floating-point MIC residual once so gain/alignment edits avoid the
 * expensive per-second FIR solve while retaining final-mix-only clipping.
 */
ProcessedMicInfo EnsureProcessedMic(const MixOptions &options, int innerFd, int micFd, int64_t totalFrames)
{
    constexpr int PROCESSED_FRAME_BYTES = CHANNELS * sizeof(float);
    const int64_t expectedBytes = totalFrames * PROCESSED_FRAME_BYTES;
    const ProcessedMicInfo retained{
        options.autoMicShiftUs, options.autoMicShiftConfidence,
        options.autoMicShiftKnown, options.autoMicShiftReliable
    };
    struct stat existing{};
    if (stat(options.processedMicPath.c_str(), &existing) == 0 && S_ISREG(existing.st_mode) &&
        existing.st_size == expectedBytes && options.autoMicShiftKnown) return retained;

    const std::string temporaryPath = options.processedMicPath + ".tmp";
    std::vector<onebeat_recording::EchoAlignmentSample> alignmentSamples;
    try {
        {
            Fd output(temporaryPath, true);
            const bool speakerMix = options.speakerBleedCancel > 0;
            constexpr int64_t ECHO_HOP_FRAMES = RATE;
            constexpr int PROCESS_BLOCK_FRAMES = 4096;
            int64_t echoAnchor = 0;
            EchoModelHistory echoHistory;
            onebeat_recording::StereoEchoFirEstimate echoBefore{}, echoAfter{};
            if (speakerMix) {
                echoBefore = EstimateEchoAt(innerFd, micFd, options.innerOffsetUs,
                    options.micOffsetUs, 0, totalFrames, options.speakerBleedCancel, echoHistory);
                CollectAlignmentSamples(echoBefore, alignmentSamples);
                echoAfter = EstimateEchoAt(innerFd, micFd, options.innerOffsetUs,
                    options.micOffsetUs, ECHO_HOP_FRAMES, totalFrames,
                    options.speakerBleedCancel, echoHistory);
                CollectAlignmentSamples(echoAfter, alignmentSamples);
            }
            std::vector<int16_t> inner, microphone;
            std::vector<float> residual;
            std::array<std::vector<int16_t>, CHANNELS> referenceBefore, referenceAfter;
            for (int64_t framePosition = 0; framePosition < totalFrames;) {
                const int frames = static_cast<int>(std::min<int64_t>(
                    PROCESS_BLOCK_FRAMES, totalFrames - framePosition));
                ReadAligned(micFd, framePosition, options.micOffsetUs, frames, microphone);
                if (speakerMix)
                    ReadAligned(innerFd, framePosition, options.innerOffsetUs, frames, inner);
                residual.resize(frames * CHANNELS);
                int processed = 0;
                while (processed < frames) {
                    const int64_t absoluteFrame = framePosition + processed;
                    if (speakerMix) {
                        while (absoluteFrame >= echoAnchor + ECHO_HOP_FRAMES) {
                            echoAnchor += ECHO_HOP_FRAMES;
                            echoBefore = echoAfter;
                            echoAfter = EstimateEchoAt(innerFd, micFd, options.innerOffsetUs,
                                options.micOffsetUs, echoAnchor + ECHO_HOP_FRAMES, totalFrames,
                                options.speakerBleedCancel, echoHistory);
                            CollectAlignmentSamples(echoAfter, alignmentSamples);
                        }
                    }
                    const int count = static_cast<int>(std::min<int64_t>(frames - processed,
                        ECHO_HOP_FRAMES - absoluteFrame % ECHO_HOP_FRAMES));
                    if (speakerMix) {
                        for (int channel = 0; channel < CHANNELS; ++channel) {
                            for (int side = 0; side < 2; ++side) {
                                const auto &model = side == 0 ?
                                    echoBefore.channels[channel] : echoAfter.channels[channel];
                                auto &reference = side == 0 ?
                                    referenceBefore[channel] : referenceAfter[channel];
                                if (!model.enabled) continue;
                                ReadAligned(innerFd, onebeat_recording::EchoFirReferenceFirstFrame(
                                    absoluteFrame, model.delayFrames), options.innerOffsetUs,
                                    count + onebeat_recording::ECHO_FIR_TAPS - 1, reference);
                            }
                        }
                    }
                    for (int frame = 0; frame < count; ++frame) {
                        const double blend =
                            static_cast<double>(absoluteFrame + frame - echoAnchor) / ECHO_HOP_FRAMES;
                        for (int channel = 0; channel < CHANNELS; ++channel) {
                            double echo = 0;
                            if (speakerMix) {
                                const auto &before = echoBefore.channels[channel];
                                const auto &after = echoAfter.channels[channel];
                                const double oldEcho = before.enabled ?
                                    onebeat_recording::PredictEchoFirSample(
                                        referenceBefore[channel].data() + frame * CHANNELS,
                                        channel, before) : 0;
                                const double newEcho = after.enabled ?
                                    onebeat_recording::PredictEchoFirSample(
                                        referenceAfter[channel].data() + frame * CHANNELS,
                                        channel, after) : 0;
                                echo = oldEcho * (1 - blend) + newEcho * blend;
                            }
                            const int index = (processed + frame) * CHANNELS + channel;
                            residual[index] = static_cast<float>(
                                static_cast<double>(microphone[index]) - echo);
                        }
                    }
                    processed += count;
                }
                WriteAll(output.value, residual.data(), residual.size() * sizeof(float));
                framePosition += frames;
            }
            Check(fsync(output.value) == 0, "净化麦克风音轨保存失败");
        }
        Check(rename(temporaryPath.c_str(), options.processedMicPath.c_str()) == 0,
            "净化麦克风音轨发布失败");
    } catch (...) {
        unlink(temporaryPath.c_str());
        throw;
    }
    const auto alignment = onebeat_recording::EstimateAutoMicAlignment(alignmentSamples);
    if (alignment.reliable) {
        return {
            static_cast<int64_t>(std::llround(
                static_cast<double>(alignment.shiftFrames) * 1000000.0 / RATE)),
            alignment.confidence, true, true
        };
    }
    return options.autoMicShiftKnown ? retained : ProcessedMicInfo{0, 0, true};
}

ProcessedMicInfo MixFile(const MixOptions &options)
{
    Check(std::isfinite(options.gain) && options.gain >= 0 && options.gain <= 2, "麦克风音量无效");
    Check(std::abs(options.micShiftUs) <= 300000, "人声对齐范围无效");
    Check(std::abs(options.autoMicShiftUs) <= 30000 &&
        std::isfinite(options.autoMicShiftConfidence) &&
        options.autoMicShiftConfidence >= 0 && options.autoMicShiftConfidence <= 1,
        "自动人声对齐参数无效");
    Check(std::isfinite(options.speakerBleedCancel) && options.speakerBleedCancel >= 0 &&
        options.speakerBleedCancel <= 4, "外放泄漏补偿无效");
    Check(options.durationMs > 0 && options.durationMs < 24 * 3600000, "录制时长无效");
    Check(options.outputPath != options.sourcePath && options.outputPath != options.innerPath &&
        options.outputPath != options.micPath && options.outputPath != options.processedMicPath,
        "导出文件不可覆盖原始音轨");
    Check(!options.processedMicPath.empty() && options.processedMicPath != options.sourcePath &&
        options.processedMicPath != options.innerPath && options.processedMicPath != options.micPath,
        "净化麦克风音轨路径无效");
    Fd sourceFile(options.sourcePath), innerFile(options.innerPath), micFile(options.micPath);
    struct stat innerStat{}, micStat{};
    Check(fstat(innerFile.value, &innerStat) == 0 && S_ISREG(innerStat.st_mode) &&
        innerStat.st_size % FRAME_BYTES == 0, "应用声音原轨格式无效");
    Check(fstat(micFile.value, &micStat) == 0 && S_ISREG(micStat.st_mode) &&
        micStat.st_size % FRAME_BYTES == 0, "麦克风原轨格式无效");
    const int64_t totalFrames = options.durationMs * RATE / 1000;
    const ProcessedMicInfo processedInfo =
        EnsureProcessedMic(options, innerFile.value, micFile.value, totalFrames);
    const int64_t effectiveMicShiftUs = options.micShiftUs + processedInfo.autoMicShiftUs;
    Check(std::abs(effectiveMicShiftUs) <= 330000, "自动与手工人声对齐范围无效");
    Fd processedMicFile(options.processedMicPath);
    struct stat processedStat{};
    constexpr int PROCESSED_FRAME_BYTES = CHANNELS * sizeof(float);
    Check(fstat(processedMicFile.value, &processedStat) == 0 && S_ISREG(processedStat.st_mode) &&
        processedStat.st_size == totalFrames * PROCESSED_FRAME_BYTES, "净化麦克风音轨格式无效");
    Fd destination(options.outputPath, true);
    struct stat stat{};
    Check(fstat(sourceFile.value, &stat) == 0 && S_ISREG(stat.st_mode) && stat.st_size > 0, "无法读取原视频");
    OH_AVSource *source = OH_AVSource_CreateWithFD(sourceFile.value, 0, stat.st_size);
    Check(source != nullptr, "原视频无法解析");
    OH_AVDemuxer *demuxer = nullptr;
    OH_AVMuxer *muxer = nullptr;
    try {
        Format sourceFormat(OH_AVSource_GetSourceFormat(source));
        int32_t trackCount = 0, videoSourceTrack = -1;
        OH_AVFormat_GetIntValue(sourceFormat.value, OH_MD_KEY_TRACK_COUNT, &trackCount);
        for (int i = 0; i < trackCount; i++) {
            Format format(OH_AVSource_GetTrackFormat(source, i));
            int32_t type = -1; OH_AVFormat_GetIntValue(format.value, OH_MD_KEY_TRACK_TYPE, &type);
            if (type == MEDIA_TYPE_VID) {
                const char *mime = nullptr;
                Check(OH_AVFormat_GetStringValue(format.value, OH_MD_KEY_CODEC_MIME, &mime) &&
                    mime != nullptr && std::strcmp(mime, "video/avc") == 0, "原视频不是受支持的 H.264 格式");
                videoSourceTrack = i;
                break;
            }
        }
        Check(videoSourceTrack >= 0, "原文件没有视频轨道");
        demuxer = OH_AVDemuxer_CreateWithSource(source);
        Check(demuxer != nullptr, "无法读取原视频帧");
        AvCheck(OH_AVDemuxer_SelectTrackByID(demuxer, videoSourceTrack), "无法选择原视频帧");
        muxer = OH_AVMuxer_Create(destination.value, AV_OUTPUT_FORMAT_MPEG_4);
        Check(muxer != nullptr, "无法创建导出视频");
        Format videoFormat(OH_AVSource_GetTrackFormat(source, videoSourceTrack));
        int32_t videoTrack = -1, audioTrack = -1;
        AvCheck(OH_AVMuxer_AddTrack(muxer, &videoTrack, videoFormat.value), "无法复制视频轨道");
        Format audioFormat(OH_AVFormat_CreateAudioFormat("audio/mp4a-latm", RATE, CHANNELS));
        OH_AVFormat_SetIntValue(audioFormat.value, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, SAMPLE_S16LE);
        OH_AVFormat_SetIntValue(audioFormat.value, OH_MD_KEY_PROFILE, AAC_PROFILE_LC);
        OH_AVFormat_SetLongValue(audioFormat.value, OH_MD_KEY_BITRATE, 192000);
        uint8_t config[] = {0x11, 0x90}; // AAC-LC, 48 kHz, two channels; matches the preserved PCM.
        OH_AVFormat_SetBuffer(audioFormat.value, OH_MD_KEY_CODEC_CONFIG, config, sizeof(config));
        AvCheck(OH_AVMuxer_AddTrack(muxer, &audioTrack, audioFormat.value), "无法添加混音轨道");
        AvCheck(OH_AVMuxer_Start(muxer), "导出封装启动失败");
        AudioEncoderQueue encoder;
        encoder.codec = OH_AudioCodec_CreateByMime("audio/mp4a-latm", true);
        Check(encoder.codec != nullptr, "AAC 编码器不可用");
        OH_AVCodecCallback callbacks{AudioEncoderQueue::Error, AudioEncoderQueue::FormatChanged,
            AudioEncoderQueue::Input, AudioEncoderQueue::Output};
        AvCheck(OH_AudioCodec_RegisterCallback(encoder.codec, callbacks, &encoder), "音频编码回调失败");
        AvCheck(OH_AudioCodec_Configure(encoder.codec, audioFormat.value), "音频编码配置失败");
        AvCheck(OH_AudioCodec_Prepare(encoder.codec), "音频编码准备失败");
        AvCheck(OH_AudioCodec_Start(encoder.codec), "音频编码启动失败");
        int64_t framePosition = 0;
        bool sentEos = false, receivedEos = false;
        std::vector<int16_t> inner;
        std::vector<float> processedMic;
        while (!receivedEos) {
            CodecBuffer input{}, output{};
            bool hasInput = false, hasOutput = false;
            {
                std::unique_lock<std::mutex> lock(encoder.mutex);
                Check(encoder.cv.wait_for(lock, 10s, [&encoder, sentEos] {
                    return encoder.error || !encoder.outputs.empty() || (!sentEos && !encoder.inputs.empty());
                }), "导出音频编码超时");
                Check(!encoder.error, "导出音频编码失败");
                if (!encoder.outputs.empty()) { output = encoder.outputs.front(); encoder.outputs.pop_front(); hasOutput = true; }
                if (!sentEos && !encoder.inputs.empty()) { input = encoder.inputs.front(); encoder.inputs.pop_front(); hasInput = true; }
            }
            if (hasOutput) {
                OH_AVCodecBufferAttr attr{}; OH_AVBuffer_GetBufferAttr(output.buffer, &attr);
                receivedEos = (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0;
                OH_AVErrCode result = AV_ERR_OK;
                if (attr.size > 0 && !(attr.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA))
                    result = OH_AVMuxer_WriteSampleBuffer(muxer, audioTrack, output.buffer);
                OH_AudioCodec_FreeOutputBuffer(encoder.codec, output.index);
                AvCheck(result, "混音写入失败");
            }
            if (hasInput) {
                int frames = static_cast<int>(std::min<int64_t>({1024, totalFrames - framePosition,
                    OH_AVBuffer_GetCapacity(input.buffer) / FRAME_BYTES}));
                OH_AVCodecBufferAttr attr{};
                attr.pts = framePosition * 1000000 / RATE;
                if (frames <= 0) { attr.flags = AVCODEC_BUFFER_FLAGS_EOS; sentEos = true; }
                else {
                    ReadAligned(innerFile.value, framePosition, options.innerOffsetUs, frames, inner);
                    ReadAlignedProcessedMic(processedMicFile.value, framePosition,
                        effectiveMicShiftUs, frames, processedMic);
                    auto *samples = reinterpret_cast<int16_t *>(OH_AVBuffer_GetAddr(input.buffer));
                    Check(samples != nullptr, "混音缓冲区不可用");
                    for (int index = 0; index < frames * CHANNELS; ++index) {
                        samples[index] = onebeat_recording::MixProcessedMicSample(
                            inner[index], processedMic[index], options.gain);
                    }
                    attr.size = frames * FRAME_BYTES;
                    framePosition += frames;
                }
                AvCheck(OH_AVBuffer_SetBufferAttr(input.buffer, &attr), "混音帧参数失败");
                AvCheck(OH_AudioCodec_PushInputBuffer(encoder.codec, input.index), "提交混音帧失败");
            }
        }
        // Video packets pass through bit-for-bit: exporting a different MIC gain
        // cannot alter scene timing, frame pacing, or the saved wave overlay.
        Buffer buffer(16 * 1024 * 1024);
        for (;;) {
            AvCheck(OH_AVDemuxer_ReadSampleBuffer(demuxer, videoSourceTrack, buffer.value), "读取视频帧失败");
            OH_AVCodecBufferAttr attr{}; OH_AVBuffer_GetBufferAttr(buffer.value, &attr);
            if (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) break;
            AvCheck(OH_AVMuxer_WriteSampleBuffer(muxer, videoTrack, buffer.value), "复制视频帧失败");
        }
        AvCheck(OH_AVMuxer_Stop(muxer), "导出视频收尾失败");
        OH_AVMuxer_Destroy(muxer); muxer = nullptr;
        OH_AVDemuxer_Destroy(demuxer); demuxer = nullptr;
        OH_AVSource_Destroy(source); source = nullptr;
    } catch (...) {
        if (muxer != nullptr) { OH_AVMuxer_Stop(muxer); OH_AVMuxer_Destroy(muxer); }
        if (demuxer != nullptr) OH_AVDemuxer_Destroy(demuxer);
        if (source != nullptr) OH_AVSource_Destroy(source);
        unlink(options.outputPath.c_str());
        throw;
    }
    return processedInfo;
}

std::mutex globalMutex;
std::shared_ptr<CaptureSession> session;
std::shared_ptr<CaptureSession> Current()
{ std::lock_guard<std::mutex> lock(globalMutex); return session; }
napi_value String(napi_env env, const std::string &text)
{ napi_value value; napi_create_string_utf8(env, text.c_str(), text.size(), &value); return value; }
napi_value Number(napi_env env, double number)
{ napi_value value; napi_create_double(env, number, &value); return value; }
void Set(napi_env env, napi_value object, const char *key, napi_value value)
{ napi_set_named_property(env, object, key, value); }
std::string GetString(napi_env env, napi_value object, const char *key)
{
    napi_value value; napi_get_named_property(env, object, key, &value);
    size_t size = 0; napi_get_value_string_utf8(env, value, nullptr, 0, &size);
    std::vector<char> text(size + 1); napi_get_value_string_utf8(env, value, text.data(), text.size(), &size);
    return std::string(text.data(), size);
}
double GetNumber(napi_env env, napi_value object, const char *key)
{ napi_value value; double result = 0; napi_get_named_property(env, object, key, &value);
  napi_get_value_double(env, value, &result); return result; }
struct AsyncJob {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::shared_ptr<CaptureSession> capture;
    MixOptions mix;
    ProcessedMicInfo mixResult;
    int kind = 0;
    std::string error;
};
void Execute(napi_env, void *data)
{
    auto *job = static_cast<AsyncJob *>(data);
    try {
        if (job->kind == 0) job->capture->Start();
        else if (job->kind == 1) { if (job->capture != nullptr) job->capture->Stop(); }
        else job->mixResult = MixFile(job->mix);
    } catch (const std::exception &err) {
        job->error = err.what();
        // The global session also owns this object, so a rejected Start job
        // does not invoke its destructor. Retire every partially opened owner
        // here, after Start's control/status locks have unwound.
        if (job->kind == 0 && job->capture != nullptr) {
            try { job->capture->Stop(); } catch (...) {}
        }
        if (job->kind == 2 && job->mix.outputPath != job->mix.sourcePath &&
            job->mix.outputPath != job->mix.innerPath && job->mix.outputPath != job->mix.micPath &&
            job->mix.outputPath != job->mix.processedMicPath) {
            // Parsing can fail before MixFile's muxer cleanup scope is entered.
            // Only discard the derived path; never unlink one of the inputs.
            unlink(job->mix.outputPath.c_str());
        }
    }
}
void Complete(napi_env env, napi_status status, void *data)
{
    std::unique_ptr<AsyncJob> job(static_cast<AsyncJob *>(data));
    napi_value value;
    if (!job->error.empty() || status != napi_ok) {
        napi_value error; napi_create_error(env, nullptr, String(env, job->error.empty() ? "录制任务异常" : job->error), &error);
        napi_reject_deferred(env, job->deferred, error);
    } else {
        if (job->kind == 1) {
            napi_create_object(env, &value);
            auto capture = job->capture;
            Set(env, value, "durationMs", Number(env, capture == nullptr ? 0 : capture->durationMs));
            Set(env, value, "micOffsetUs", Number(env, capture == nullptr ? 0 : capture->micOffsetUs));
            Set(env, value, "innerOffsetUs", Number(env, capture == nullptr ? 0 : capture->innerOffsetUs));
            Set(env, value, "timestampMappingVersion", Number(env, 2));
            Set(env, value, "videoTimestampDivisor", Number(env, capture == nullptr ? 0 : capture->videoTimestampDivisor));
            Set(env, value, "videoFirstPtsUs", Number(env, capture == nullptr ? -1 : capture->firstVideoPtsUs));
            Set(env, value, "videoLastPtsUs", Number(env, capture == nullptr ? -1 : capture->lastVideoPtsUs));
            Set(env, value, "micFirstPtsUs", Number(env, capture == nullptr ? -1 : capture->micFirstPtsUs));
            Set(env, value, "innerFirstPtsUs", Number(env, capture == nullptr ? -1 : capture->innerFirstPtsUs));
            napi_value valid; napi_get_boolean(env, capture == nullptr || capture->syncValid, &valid);
            Set(env, value, "syncValid", valid);
        } else if (job->kind == 2) {
            napi_create_object(env, &value);
            Set(env, value, "autoMicShiftUs", Number(env, job->mixResult.autoMicShiftUs));
            Set(env, value, "autoMicShiftConfidence", Number(env, job->mixResult.confidence));
            napi_value reliable; napi_get_boolean(env, job->mixResult.reliable, &reliable);
            Set(env, value, "autoMicShiftReliable", reliable);
        } else napi_get_undefined(env, &value);
        napi_resolve_deferred(env, job->deferred, value);
    }
    napi_delete_async_work(env, job->work);
}
napi_value Queue(napi_env env, AsyncJob *job)
{
    napi_value promise;
    napi_create_promise(env, &job->deferred, &promise);
    napi_create_async_work(env, nullptr, String(env, "onebeat.recording"), Execute, Complete, job, &job->work);
    napi_queue_async_work(env, job->work);
    return promise;
}
napi_value Start(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1]; napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto capture = std::make_shared<CaptureSession>();
    capture->videoPath = GetString(env, args[0], "videoPath");
    capture->innerPath = GetString(env, args[0], "innerPath");
    capture->micPath = GetString(env, args[0], "micPath");
    capture->width = static_cast<int>(GetNumber(env, args[0], "width"));
    capture->height = static_cast<int>(GetNumber(env, args[0], "height"));
    { std::lock_guard<std::mutex> lock(globalMutex); session = capture; }
    auto *job = new AsyncJob(); job->capture = capture; return Queue(env, job);
}
napi_value Stop(napi_env env, napi_callback_info)
{ auto *job = new AsyncJob(); job->kind = 1; job->capture = Current();
  if (job->capture != nullptr) job->capture->Cancel(); return Queue(env, job); }
napi_value Cancel(napi_env env, napi_callback_info)
{ auto capture = Current(); if (capture != nullptr) capture->Cancel(); napi_value value;
  napi_get_undefined(env, &value); return value; }
napi_value Status(napi_env env, napi_callback_info)
{
    auto capture = Current(); napi_value value; napi_create_object(env, &value);
    Set(env, value, "stateCode", Number(env, capture == nullptr ? -1 : capture->state.load()));
    Set(env, value, "amplitude", Number(env, capture == nullptr ? 0 : capture->peak.exchange(0)));
    Set(env, value, "error", String(env, capture == nullptr ? "" : capture->Error()));
    return value;
}
napi_value Mix(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1]; napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto *job = new AsyncJob(); job->kind = 2;
    job->mix.sourcePath = GetString(env, args[0], "sourcePath");
    job->mix.innerPath = GetString(env, args[0], "innerPath");
    job->mix.micPath = GetString(env, args[0], "micPath");
    job->mix.outputPath = GetString(env, args[0], "outputPath");
    job->mix.processedMicPath = GetString(env, args[0], "processedMicPath");
    job->mix.durationMs = GetNumber(env, args[0], "durationMs");
    job->mix.micOffsetUs = GetNumber(env, args[0], "micOffsetUs");
    job->mix.innerOffsetUs = GetNumber(env, args[0], "innerOffsetUs");
    job->mix.micShiftUs = GetNumber(env, args[0], "micShiftUs");
    job->mix.autoMicShiftUs = GetNumber(env, args[0], "autoMicShiftUs");
    job->mix.autoMicShiftKnown = GetNumber(env, args[0], "autoMicShiftKnown") != 0;
    job->mix.autoMicShiftReliable = GetNumber(env, args[0], "autoMicShiftReliable") != 0;
    job->mix.autoMicShiftConfidence = GetNumber(env, args[0], "autoMicShiftConfidence");
    job->mix.gain = GetNumber(env, args[0], "gain");
    job->mix.speakerBleedCancel = GetNumber(env, args[0], "speakerBleedCancel");
    return Queue(env, job);
}
napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancel", nullptr, Cancel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getStatus", nullptr, Status, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mix", nullptr, Mix, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
    return exports;
}
napi_module module{1, 0, nullptr, Init, "onebeat_recording", nullptr, {0}};
__attribute__((constructor)) void Register() { napi_module_register(&module); }
} // namespace
