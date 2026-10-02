package com.example.facedetectionapp.data

import androidx.room.Entity
import androidx.room.PrimaryKey

// 여기가 바로 '데이터베이스 테이블' 설계도입니다.
@Entity(tableName = "person_table")
data class Person(
    // 1. 고유 ID (자동으로 1, 2, 3... 번호표가 붙습니다)
    @PrimaryKey(autoGenerate = true) val id: Int = 0,

    // 2. 사람 기본 정보
    val name: String,             // 이름 (필수)
    val info: String = "",        // 메모/특이사항

    // 3. 비즈니스 정보 (CRM용 - 나중에 주소록이랑 연결될 부분)
    val phoneNumber: String? = null, // 전화번호
    val email: String? = null,       // 이메일
    val company: String? = null,     // 회사
    val jobTitle: String? = null,    // 직함

    // 4. 안면 인식 데이터 (중요 ★)
    // 아까 만든 Converters 덕분에 복잡한 얼굴 데이터도 저장이 가능합니다.
    val embeddings: List<FloatArray> = emptyList(),

    // 5. 얼굴 사진 썸네일 (JPEG 바이트, 96×96)
    val photoThumbnails: List<ByteArray> = emptyList(),

    // 6. 언제 등록했는지
    val createdAt: Long = System.currentTimeMillis()
)