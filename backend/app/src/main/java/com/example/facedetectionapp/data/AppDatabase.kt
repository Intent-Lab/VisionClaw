package com.example.facedetectionapp.data

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.TypeConverters

// 1. 사용할 테이블(Person)과 버전(1)을 명시합니다.
@Database(entities = [Person::class], version = 2, exportSchema = false)
// 2. 아까 만든 변환기(Converters)를 여기에 등록해야 벡터 저장이 가능합니다.
@TypeConverters(Converters::class)
abstract class AppDatabase : RoomDatabase() {

    // DAO를 꺼낼 수 있는 구멍을 뚫어줍니다.
    abstract fun personDao(): PersonDao

    companion object {
        @Volatile
        private var INSTANCE: AppDatabase? = null

        // DB는 딱 하나만 만들어져야 합니다 (싱글톤 패턴)
        fun getDatabase(context: Context): AppDatabase {
            return INSTANCE ?: synchronized(this) {
                val instance = Room.databaseBuilder(
                    context.applicationContext,
                    AppDatabase::class.java,
                    "crm_database" // 스마트폰 내부에 저장될 실제 파일 이름
                )
                    .fallbackToDestructiveMigration() // 개발 중 DB 구조가 바뀌면, 에러 대신 기존 데이터를 지우고 새로 시작
                    .build()
                INSTANCE = instance
                instance
            }
        }
    }
}