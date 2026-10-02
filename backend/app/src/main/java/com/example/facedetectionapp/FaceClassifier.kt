package com.example.facedetectionapp

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import org.tensorflow.lite.Interpreter
// GPU 임포트 제거됨
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.io.FileInputStream
import java.nio.channels.FileChannel

class FaceClassifier(private val context: Context) {

    private var interpreter: Interpreter? = null

    // 모델 입력/출력 크기
    private val inputSize = 112
    private val outputSize = 192

    init {
        // [수정] GPU 코드 제거, CPU만 사용 (안정성 확보)
        val options = Interpreter.Options().apply {
            setNumThreads(4)
        }

        try {
            // 모델 로드
            interpreter = Interpreter(loadModelFile("mobile_face_net.tflite"), options)
            Log.d("FaceClassifier", "모델 로드 성공 (CPU 모드)")

        } catch (e: Exception) {
            Log.e("FaceClassifier", "모델 로드 실패", e)
            throw RuntimeException("모델 파일을 찾을 수 없습니다. (assets/mobile_face_net.tflite 확인)")
        }
    }

    // [핵심 함수] 이미지 -> 정규화된 임베딩 벡터 반환
    fun getFaceEmbedding(bitmap: Bitmap): FloatArray {
        // 1. 이미지 리사이징
        val scaledBitmap = Bitmap.createScaledBitmap(bitmap, inputSize, inputSize, true)

        // 2. 입력 데이터 준비
        val inputBuffer = convertBitmapToByteBuffer(scaledBitmap)

        // 3. 출력 담을 그릇
        val outputBuffer = Array(1) { FloatArray(outputSize) }

        // 4. 추론 실행
        interpreter?.run(inputBuffer, outputBuffer)

        // 5. [★중요★] L2 정규화 수행! (이게 빠져서 인식이 안 됐던 겁니다)
        return l2Normalize(outputBuffer[0])
    }

    // ★★★ [인식률 해결사] 벡터 정규화 함수 ★★★
    private fun l2Normalize(vector: FloatArray): FloatArray {
        var sum = 0.0f
        for (v in vector) {
            sum += v * v
        }
        // 0으로 나누기 방지
        val norm = Math.sqrt(sum.toDouble()).toFloat() + 1e-5f

        // 모든 값을 벡터의 길이(norm)로 나눠줌
        return FloatArray(vector.size) { index ->
            vector[index] / norm
        }
    }

    // 이미지 전처리 (픽셀 정규화: -1.0 ~ 1.0)
    private fun convertBitmapToByteBuffer(bitmap: Bitmap): ByteBuffer {
        val byteBuffer = ByteBuffer.allocateDirect(4 * inputSize * inputSize * 3)
        byteBuffer.order(ByteOrder.nativeOrder())

        val intValues = IntArray(inputSize * inputSize)
        bitmap.getPixels(intValues, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)

        var pixel = 0
        for (i in 0 until inputSize) {
            for (j in 0 until inputSize) {
                val msg = intValues[pixel++]

                val r = (msg shr 16 and 0xFF).toFloat()
                val g = (msg shr 8 and 0xFF).toFloat()
                val b = (msg and 0xFF).toFloat()

                byteBuffer.putFloat((r - 128.0f) / 128.0f)
                byteBuffer.putFloat((g - 128.0f) / 128.0f)
                byteBuffer.putFloat((b - 128.0f) / 128.0f)
            }
        }
        return byteBuffer
    }

    // 모델 파일 로드
    private fun loadModelFile(modelName: String): ByteBuffer {
        val fileDescriptor = context.assets.openFd(modelName)
        val inputStream = FileInputStream(fileDescriptor.fileDescriptor)
        val fileChannel = inputStream.channel
        val startOffset = fileDescriptor.startOffset
        val declaredLength = fileDescriptor.declaredLength
        return fileChannel.map(FileChannel.MapMode.READ_ONLY, startOffset, declaredLength)
    }

    // 거리 계산 (유클리드 거리)
    fun calculateDistance(embedding1: FloatArray, embedding2: FloatArray): Float {
        var sum = 0.0f
        for (i in embedding1.indices) {
            val diff = embedding1[i] - embedding2[i]
            sum += diff * diff
        }
        return Math.sqrt(sum.toDouble()).toFloat()
    }
}