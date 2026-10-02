package com.example.facedetectionapp.data

import androidx.room.*
import kotlinx.coroutines.flow.Flow

@Dao
interface PersonDao {
    // 1. [저장] 사람 추가하기 (이름이 같아도 ID가 다르면 추가됨)
    // 반환값 Long은 새로 생긴 ID 번호입니다.
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertPerson(person: Person): Long

    // 2. [조회] 모든 사람 목록 가져오기
    // Flow는 데이터가 바뀌면 자동으로 화면도 업데이트해주는 기능입니다. (실시간 감시)
    @Query("SELECT * FROM person_table ORDER BY createdAt DESC")
    fun getAllPeople(): Flow<List<Person>>

    // 3. [조회] 특정 ID의 사람 정보만 쏙 가져오기
    @Query("SELECT * FROM person_table WHERE id = :id")
    suspend fun getPersonById(id: Int): Person?

    // 4. [검색] 이름으로 검색하기 (예: '김' 검색 -> 김윤섭, 김철수)
    @Query("SELECT * FROM person_table WHERE name LIKE '%' || :searchQuery || '%'")
    fun searchPeople(searchQuery: String): Flow<List<Person>>

    // 5. [수정] 정보 업데이트 (얼굴 데이터 추가, 메모 수정 등)
    @Update
    suspend fun updatePerson(person: Person)

    // 6. [삭제] 사람 지우기
    @Delete
    suspend fun deletePerson(person: Person)
}