import Foundation
import Observation

@MainActor
@Observable
final class DateManager {
    var selectedDate: Date

    @ObservationIgnored
    private let calendar: Calendar

    @ObservationIgnored
    private static let seoulTimeZone = TimeZone(identifier: "Asia/Seoul") ?? .current

    @ObservationIgnored
    private lazy var formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = DateManager.seoulTimeZone
        formatter.dateStyle = .full
        return formatter
    }()

    init(referenceDate: Date = Date()) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ko_KR")
        calendar.timeZone = DateManager.seoulTimeZone
        self.calendar = calendar
        self.selectedDate = referenceDate
    }

    var formattedSelectedDate: String {
        formatter.string(from: selectedDate)
    }
    
    var minDate: Date {
        calendar.startOfDay(for: Date()) // 오늘 (자정 기준)
    }
    
    var maxDate: Date {
        let today = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: 7, to: today) ?? today // 오늘 + 7일 (자정 기준)
    }

    func move(by days: Int) {
        guard let newDate = calendar.date(byAdding: .day, value: days, to: selectedDate) else { return }
        
        // 날짜 범위 체크
        let today = calendar.startOfDay(for: Date())
        let maxAllowed = calendar.startOfDay(for: maxDate)
        let newDay = calendar.startOfDay(for: newDate)
        
        // 과거 날짜나 7일 이후 날짜는 이동 불가
        if newDay < today || newDay > maxAllowed {
            return
        }
        
        selectedDate = newDate
    }

    func resetToToday() {
        selectedDate = Date()
    }
}

