import Foundation

struct OperatingHours: Hashable {
    let day: String          // 주간 (예: "09:00 - 16:30")
    let night: String?       // 야간 (예: "18:30 - 22:00")
    let lateNight: String?   // 심야 (예: "22:00 - 02:00")
    
    /// 단일 운영 시간만 있을 때 간편 생성
    static func simple(_ hours: String) -> OperatingHours {
        OperatingHours(
            day: hours,
            night: nil,
            lateNight: nil
        )
    }
    
    /// 카드용 간략 표시 (주간 시간만)
    var shortSummary: String {
        if night != nil {
            return "주간 \(day)"
        }
        return day
    }
    
    /// 상세 화면용 전체 표시
    var detailText: String {
        var text = "주간 \(day)"
        if let night = night {
            text += " | 야간 \(night)"
        }
        if let lateNight = lateNight {
            text += " | 심야 \(lateNight)"
        }
        return text
    }
}

struct Resort: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let latitude: Double
    let longitude: Double
    let homePageURL: String
    let slopeStatusURL: String
    let webCamURL: String?
    let operatingHours: OperatingHours
}

let resorts: [Resort] = [
    // 1. 하이원 (강원 정선)
    Resort(
        name: "하이원 리조트",
        latitude: 37.2067,
        longitude: 128.8390,
        homePageURL: "https://www.high1.com",
        slopeStatusURL: "https://www.high1.com/ski/slopeView.do?key=748&mode=p",
        webCamURL: nil,
        operatingHours: OperatingHours(
            day: "09:00 - 16:00",
            night: "18:00 - 22:00",
            lateNight: nil
        )
    ),
    
    // 2. 용평 리조트 (강원 평창)
    Resort(
        name: "모나 용평",
        latitude: 37.6450,
        longitude: 128.6810,
        homePageURL: "https://www.yongpyong.co.kr",
        slopeStatusURL: "https://www.yongpyong.co.kr/kor/skiNboard/slope/openStatusBoard.do",
        webCamURL: "https://www.yongpyong.co.kr/kor/guide/realTimeNews/ypResortWebcam.do",
        operatingHours: OperatingHours(
            day: "09:00 - 17:00",
            night: "18:30 - 22:00",
            lateNight: nil
        )
    ),
    
    // 3. 비발디파크 (강원 홍천)
    Resort(
        name: "비발디파크",
        latitude: 37.6480,
        longitude: 127.6840,
        homePageURL: "https://www.sonohotelsresorts.com/vp",
        slopeStatusURL: "https://www.sonohotelsresorts.com/skiboard/status",
        webCamURL: nil,
        operatingHours: OperatingHours(
            day: "08:30 - 16:30",
            night: "18:30 - 22:30",
            lateNight: "22:00 - 익일 03:00"
        )
    ),
    
    // 4. 휘닉스 평창 (강원 평창)
    Resort(
        name: "휘닉스 평창",
        latitude: 37.5834,
        longitude: 128.3254,
        homePageURL: "https://phoenixhnr.co.kr/pyeongchang/index",
        slopeStatusURL: "https://phoenixhnr.co.kr/static/pyeongchang/snowpark/slope-lift",
        webCamURL: "https://phoenixhnr.co.kr/page/pyeongchang/guide/operation/sketchMovie",
        operatingHours: OperatingHours(
            day: "09:00 - 16:00",
            night: "18:00 - 22:00",
            lateNight: "22:00 - 24:00"
        )
    ),
    
    // 5. 웰리힐리파크 (강원 횡성)
    Resort(
        name: "웰리힐리파크",
        latitude: 37.4906,
        longitude: 128.2506,
        homePageURL: "https://www.wellihillipark.com",
        slopeStatusURL: "https://m.wellihillipark.com/snowpark/schedule/open-slope",
        webCamURL: "https://m.wellihillipark.com/customer/webcam",
        operatingHours: OperatingHours(
            day: "09:00 - 16:30",
            night: "18:30 - 22:30",
            lateNight: "22:30 - 24:00"
        )
    ),
    
    // 6. 알펜시아 (강원 평창)
    Resort(
        name: "알펜시아",
        latitude: 37.6628,
        longitude: 128.6814,
        homePageURL: "https://www.alpensia.com",
        slopeStatusURL: "https://www.alpensia.com/ski/slope-now.do",
        webCamURL: "https://www.alpensia.com/guide/web-cam.do",
        operatingHours: OperatingHours(
            day: "09:00 - 17:00",
            night: "18:30 - 21:30",
            lateNight: nil
        )
    ),
    
    // 7. 엘리시안 강촌 (강원 춘천)
    Resort(
        name: "엘리시안 강촌",
        latitude: 37.8164,
        longitude: 127.5870,
        homePageURL: "https://www.elysian.co.kr",
        slopeStatusURL: "https://www.elysian.co.kr/about-gangchon/sky#guide-to-using-slopes",
        webCamURL: nil,
        operatingHours: OperatingHours(
            day: "09:00 - 17:00",
            night: "18:30 - 24:00(일~목)",
            lateNight: "18:30 - 03:00 (금,토)"
        )
    ),
    
    // 8. 오투리조트 (강원 태백)
    Resort(
        name: "오투리조트",
        latitude: 37.1775,
        longitude: 128.9478,
        homePageURL: "https://www.o2resort.com",
        slopeStatusURL: "https://www.o2resort.com/SKI/slopeOpen.jsp",
        webCamURL: "https://www.o2resort.com/SKI/liftInfo.jsp",
        operatingHours: OperatingHours(
            day: "09:00 - 16:30",
            night: "18:00 - 21:30",
            lateNight: nil
        )
    ),
    
    // 9. 곤지암 리조트 (경기 광주)
    Resort(
        name: "곤지암 리조트",
        latitude: 37.3369,
        longitude: 127.2936,
        homePageURL: "https://www.konjiamresort.co.kr",
        slopeStatusURL: "https://www.konjiamresort.co.kr/ski/slopeOpenClose.dev",
        webCamURL: "https://www.konjiamresort.co.kr/ski/liveCam.dev",
        operatingHours: OperatingHours(
            day: "09:00 - 17:00",
            night: "19:00 - 22:00",
            lateNight: "22:00 - 02:00"
        )
    ),
    
    // 10. 지산 포레스트 (경기 이천)
    Resort(
        name: "지산 포레스트",
        latitude: 37.2167,
        longitude: 127.3453,
        homePageURL: "https://www.jisanresort.co.kr",
        slopeStatusURL: "https://www.jisanresort.co.kr/m/ski/slopes/info.asp",
        webCamURL: "https://www.jisanresort.co.kr/m/ski/slopes/webcam.asp",
        operatingHours: OperatingHours(
            day: "09:00 - 17:00",
            night: "18:30 - 23:00",
            lateNight: "23:00 - 02:00"
        )
    ),
    
    // 11. 무주 덕유산 (전북 무주)
    Resort(
        name: "무주 덕유산",
        latitude: 35.8908,
        longitude: 127.7369,
        homePageURL: "https://www.mdysresort.com",
        slopeStatusURL: "https://www.mdysresort.com/convert_main_slope_221207.asp",
        webCamURL: "https://www.mdysresort.com/guide/webcam.asp",
        operatingHours: OperatingHours(
            day: "09:30 - 16:00",
            night: "18:30 - 22:00",
            lateNight: "22:00 - 24:00"
        )
    ),
    
    // 12. 에덴밸리 (경남 양산)
    Resort(
        name: "에덴밸리",
        latitude: 35.4289,
        longitude: 128.9844,
        homePageURL: "http://www.edenvalley.co.kr",
        slopeStatusURL: "https://www.edenvalley.co.kr/Ski/View.asp?location=01-1",
        webCamURL: "https://www.edenvalley.co.kr/CS/cam_pop1.asp",
        operatingHours: OperatingHours(
            day: "10:00 - 17:00",
            night: "19:00 - 23:00",
            lateNight: nil
        )
    )
]

#if DEBUG
extension Resort {
    static var preview: Resort {
        resorts.first ?? Resort(
            name: "프리뷰 리조트",
            latitude: 37.5,
            longitude: 127.0,
            homePageURL: "https://example.com",
            slopeStatusURL: "https://example.com/slope",
            webCamURL: nil,
            operatingHours: .simple("09:00 - 18:00")
        )
    }
}
#endif

