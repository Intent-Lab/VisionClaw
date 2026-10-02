#include <jni.h>
#include <android/log.h>
#include <stdlib.h>
#include "whisper.h"

#define TAG "JarvisWhisperJNI"
#define UNUSED(x) (void)(x)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

JNIEXPORT jlong JNICALL
Java_com_meta_wearable_dat_externalsampleapps_cameraaccess_whisper_WhisperNative_00024Companion_initContext(
        JNIEnv *env, jobject thiz, jstring model_path_str) {
    UNUSED(thiz);
    const char *model_path_chars = (*env)->GetStringUTFChars(env, model_path_str, NULL);
    struct whisper_context *context = whisper_init_from_file_with_params(
            model_path_chars,
            whisper_context_default_params()
    );
    (*env)->ReleaseStringUTFChars(env, model_path_str, model_path_chars);
    return (jlong) context;
}

JNIEXPORT void JNICALL
Java_com_meta_wearable_dat_externalsampleapps_cameraaccess_whisper_WhisperNative_00024Companion_freeContext(
        JNIEnv *env, jobject thiz, jlong context_ptr) {
    UNUSED(env);
    UNUSED(thiz);
    struct whisper_context *context = (struct whisper_context *) context_ptr;
    if (context != NULL) {
        whisper_free(context);
    }
}

JNIEXPORT void JNICALL
Java_com_meta_wearable_dat_externalsampleapps_cameraaccess_whisper_WhisperNative_00024Companion_fullTranscribe(
        JNIEnv *env,
        jobject thiz,
        jlong context_ptr,
        jint num_threads,
        jstring language_str,
        jfloatArray audio_data) {
    UNUSED(thiz);
    struct whisper_context *context = (struct whisper_context *) context_ptr;
    if (context == NULL) return;

    const char *language_chars = (*env)->GetStringUTFChars(env, language_str, NULL);
    jfloat *audio_data_arr = (*env)->GetFloatArrayElements(env, audio_data, NULL);
    const jsize audio_data_length = (*env)->GetArrayLength(env, audio_data);

    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.print_realtime = false;
    params.print_progress = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.translate = false;
    params.language = language_chars;
    params.n_threads = num_threads;
    params.offset_ms = 0;
    params.no_context = true;
    params.single_segment = true;
    params.suppress_blank = true;

    whisper_reset_timings(context);

    LOGI("Running whisper_full len=%d threads=%d language=%s", audio_data_length, num_threads, language_chars);
    if (whisper_full(context, params, audio_data_arr, audio_data_length) != 0) {
        LOGI("whisper_full failed");
    }

    (*env)->ReleaseFloatArrayElements(env, audio_data, audio_data_arr, JNI_ABORT);
    (*env)->ReleaseStringUTFChars(env, language_str, language_chars);
}

JNIEXPORT jint JNICALL
Java_com_meta_wearable_dat_externalsampleapps_cameraaccess_whisper_WhisperNative_00024Companion_getTextSegmentCount(
        JNIEnv *env, jobject thiz, jlong context_ptr) {
    UNUSED(env);
    UNUSED(thiz);
    struct whisper_context *context = (struct whisper_context *) context_ptr;
    if (context == NULL) return 0;
    return whisper_full_n_segments(context);
}

JNIEXPORT jstring JNICALL
Java_com_meta_wearable_dat_externalsampleapps_cameraaccess_whisper_WhisperNative_00024Companion_getTextSegment(
        JNIEnv *env, jobject thiz, jlong context_ptr, jint index) {
    UNUSED(thiz);
    struct whisper_context *context = (struct whisper_context *) context_ptr;
    if (context == NULL) return (*env)->NewStringUTF(env, "");
    const char *text = whisper_full_get_segment_text(context, index);
    return (*env)->NewStringUTF(env, text);
}

JNIEXPORT jstring JNICALL
Java_com_meta_wearable_dat_externalsampleapps_cameraaccess_whisper_WhisperNative_00024Companion_getSystemInfo(
        JNIEnv *env, jobject thiz) {
    UNUSED(thiz);
    const char *sysinfo = whisper_print_system_info();
    return (*env)->NewStringUTF(env, sysinfo);
}
