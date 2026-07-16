// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "runtime-core.h"

#include <jni.h>

#include <algorithm>
#include <cstdint>
#include <exception>
#include <limits>
#include <memory>
#include <string>
#include <vector>

namespace {

void throw_java(JNIEnv* environment, const char* class_name, const std::string& message) {
    if (jclass error_class = environment->FindClass(class_name); error_class != nullptr) {
        environment->ThrowNew(error_class, message.c_str());
    }
}

vibestation::GuestRuntime* runtime_from(jlong handle) {
    return reinterpret_cast<vibestation::GuestRuntime*>(static_cast<std::uintptr_t>(handle));
}

}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_mcruz_vibestation5_core_NativeBridge_nativeCreateRuntime(
    JNIEnv* environment,
    jobject,
    jbyteArray input,
    jstring content_root
) {
    if (input == nullptr) {
        throw_java(environment, "java/lang/IllegalArgumentException", "The executable data is null.");
        return 0;
    }
    const jsize length = environment->GetArrayLength(input);
    std::vector<std::uint8_t> data(static_cast<std::size_t>(length));
    environment->GetByteArrayRegion(input, 0, length, reinterpret_cast<jbyte*>(data.data()));
    if (environment->ExceptionCheck()) return 0;
    std::string root;
    if (content_root != nullptr) {
        const char* characters = environment->GetStringUTFChars(content_root, nullptr);
        if (characters == nullptr) return 0;
        root = characters;
        environment->ReleaseStringUTFChars(content_root, characters);
    }
    try {
        auto runtime = std::make_unique<vibestation::GuestRuntime>(std::move(data), std::move(root));
        return static_cast<jlong>(reinterpret_cast<std::uintptr_t>(runtime.release()));
    } catch (const std::exception& error) {
        throw_java(environment, "java/lang/IllegalArgumentException", error.what());
        return 0;
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_mcruz_vibestation5_core_NativeBridge_nativeDestroyRuntime(
    JNIEnv*,
    jobject,
    jlong handle
) {
    delete runtime_from(handle);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_mcruz_vibestation5_core_NativeBridge_nativeRuntimeDescription(
    JNIEnv* environment,
    jobject,
    jlong handle
) {
    vibestation::GuestRuntime* runtime = runtime_from(handle);
    if (runtime == nullptr) {
        throw_java(environment, "java/lang/IllegalStateException", "The native guest runtime is closed.");
        return nullptr;
    }
    const std::string description = runtime->description();
    return environment->NewStringUTF(description.c_str());
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_mcruz_vibestation5_core_NativeBridge_nativeRunRuntime(
    JNIEnv* environment,
    jobject,
    jlong handle,
    jlong instruction_budget
) {
    vibestation::GuestRuntime* runtime = runtime_from(handle);
    if (runtime == nullptr) {
        throw_java(environment, "java/lang/IllegalStateException", "The native guest runtime is closed.");
        return nullptr;
    }
    if (instruction_budget <= 0) {
        throw_java(environment, "java/lang/IllegalArgumentException", "The instruction budget must be positive.");
        return nullptr;
    }
    try {
        const std::string result = runtime->run(static_cast<std::uint64_t>(instruction_budget)).json();
        return environment->NewStringUTF(result.c_str());
    } catch (const std::exception& error) {
        throw_java(environment, "java/lang/IllegalStateException", error.what());
        return nullptr;
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_mcruz_vibestation5_core_NativeBridge_nativeSetInput(
    JNIEnv* environment,
    jobject,
    jlong handle,
    jlong buttons,
    jfloat left_x,
    jfloat left_y,
    jfloat right_x,
    jfloat right_y
) {
    vibestation::GuestRuntime* runtime = runtime_from(handle);
    if (runtime == nullptr) {
        throw_java(environment, "java/lang/IllegalStateException", "The native guest runtime is closed.");
        return;
    }
    runtime->set_input(
        static_cast<std::uint64_t>(buttons),
        left_x,
        left_y,
        right_x,
        right_y
    );
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_mcruz_vibestation5_core_NativeBridge_nativeDrainAudio(
    JNIEnv* environment,
    jobject,
    jlong handle
) {
    vibestation::GuestRuntime* runtime = runtime_from(handle);
    if (runtime == nullptr) {
        throw_java(environment, "java/lang/IllegalStateException", "The native guest runtime is closed.");
        return nullptr;
    }
    const std::vector<std::uint8_t> audio = runtime->drain_audio();
    jbyteArray result = environment->NewByteArray(static_cast<jsize>(audio.size()));
    if (result != nullptr && !audio.empty()) {
        environment->SetByteArrayRegion(
            result,
            0,
            static_cast<jsize>(audio.size()),
            reinterpret_cast<const jbyte*>(audio.data())
        );
    }
    return result;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_mcruz_vibestation5_core_NativeBridge_nativeAudioSampleRate(
    JNIEnv* environment,
    jobject,
    jlong handle
) {
    vibestation::GuestRuntime* runtime = runtime_from(handle);
    if (runtime == nullptr) {
        throw_java(environment, "java/lang/IllegalStateException", "The native guest runtime is closed.");
        return 0;
    }
    return static_cast<jint>(runtime->audio_sample_rate());
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_mcruz_vibestation5_core_NativeBridge_nativeReadVideoFrame(
    JNIEnv* environment,
    jobject,
    jlong handle,
    jlong after_sequence
) {
    vibestation::GuestRuntime* runtime = runtime_from(handle);
    if (runtime == nullptr) {
        throw_java(environment, "java/lang/IllegalStateException", "The native guest runtime is closed.");
        return nullptr;
    }

    const vibestation::GuestVideoFrame frame = runtime->latest_video_frame(static_cast<std::uint64_t>(after_sequence));
    if (frame.bgra8888.empty()) return environment->NewByteArray(0);

    constexpr std::size_t header_size = 16;
    if (frame.bgra8888.size() > static_cast<std::size_t>(std::numeric_limits<jsize>::max()) - header_size) {
        throw_java(environment, "java/lang/IllegalStateException", "The guest video frame exceeds the JNI byte-array limit.");
        return nullptr;
    }

    std::vector<std::uint8_t> packet(header_size + frame.bgra8888.size());
    const auto write_little_endian = [&packet](std::size_t offset, std::uint64_t value, std::size_t size) {
        for (std::size_t index = 0; index < size; ++index) {
            packet[offset + index] = static_cast<std::uint8_t>(value >> (index * 8U));
        }
    };
    write_little_endian(0, frame.width, 4);
    write_little_endian(4, frame.height, 4);
    write_little_endian(8, frame.sequence, 8);
    std::copy(frame.bgra8888.begin(), frame.bgra8888.end(), packet.begin() + header_size);

    jbyteArray result = environment->NewByteArray(static_cast<jsize>(packet.size()));
    if (result != nullptr) {
        environment->SetByteArrayRegion(
            result,
            0,
            static_cast<jsize>(packet.size()),
            reinterpret_cast<const jbyte*>(packet.data())
        );
    }
    return result;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_mcruz_vibestation5_core_NativeBridge_nativeDumpGpuCapture(
    JNIEnv* environment,
    jobject,
    jlong handle,
    jstring directory
) {
    vibestation::GuestRuntime* runtime = runtime_from(handle);
    if (runtime == nullptr) {
        throw_java(environment, "java/lang/IllegalStateException", "The native guest runtime is closed.");
        return nullptr;
    }
    if (directory == nullptr) {
        throw_java(environment, "java/lang/IllegalArgumentException", "The GPU capture directory is required.");
        return nullptr;
    }
    const char* characters = environment->GetStringUTFChars(directory, nullptr);
    if (characters == nullptr) return nullptr;
    const std::string path(characters);
    environment->ReleaseStringUTFChars(directory, characters);
    try {
        const std::string manifest = runtime->dump_gpu_capture(path);
        return environment->NewStringUTF(manifest.c_str());
    } catch (const std::exception& error) {
        throw_java(environment, "java/lang/IllegalStateException", error.what());
        return nullptr;
    }
}
