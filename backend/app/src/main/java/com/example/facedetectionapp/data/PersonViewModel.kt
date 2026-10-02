package com.example.facedetectionapp.data

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

// 1. AndroidViewModel 상속: DB를 만들려면 'Context(앱 환경정보)'가 필요한데,
// 일반 ViewModel은 그걸 몰라서 AndroidViewModel을 씁니다.
class PersonViewModel(application: Application) : AndroidViewModel(application) {

    // 2. DB와 DAO 연결: "주방장(DAO) 불러오기"
    // 앱 전체에서 DB는 하나만 있어야 하므로 getDatabase()로 가져옵니다.
    private val dao = AppDatabase.getDatabase(application).personDao()

    // 3. 데이터 관찰 (StateFlow): "실시간 메뉴판"
    // - UI는 이 'allPeople'만 쳐다보고 있으면 됩니다.
    // - DB에 데이터가 추가/삭제되면, 알아서 UI에도 즉시 반영됩니다 (자동 동기화).
    val allPeople = dao.getAllPeople()
        .stateIn(
            scope = viewModelScope, // 뷰모델이 살아있는 동안만 작동
            started = SharingStarted.WhileSubscribed(5000), // 화면이 꺼져도 5초간은 대기(성능 최적화)
            initialValue = emptyList() // 데이터 로딩 전 초기값
        )

    // 4. [기능] 사람 추가 (Create)
    // - UI에서 버튼을 누르면 이 함수가 실행됩니다.
    // - viewModelScope.launch: "별도 작업 스레드(코루틴)"에서 실행합니다.
    //   (메인 화면이 멈추지 않게 백그라운드에서 저장)
    fun addPerson(
        name: String,
        info: String,
        embeddings: List<FloatArray>,
        phone: String? = null,
        email: String? = null,
        thumbnails: List<ByteArray> = emptyList()
    ) {
        viewModelScope.launch {
            val newPerson = Person(
                name = name,
                info = info,
                embeddings = embeddings,
                phoneNumber = phone,
                email = email,
                photoThumbnails = thumbnails
            )
            dao.insertPerson(newPerson)
        }
    }

    // 5. [기능] 사람 정보 수정 (Update)
    fun updatePerson(person: Person) {
        viewModelScope.launch {
            dao.updatePerson(person)
        }
    }

    // 6. [기능] 사람 삭제 (Delete)
    fun deletePerson(person: Person) {
        viewModelScope.launch {
            dao.deletePerson(person)
        }
    }
}