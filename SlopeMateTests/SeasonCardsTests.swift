import Foundation
import Testing
@testable import SlopeMate

struct SeasonCardsTests {
    let a = UUID(), b = UUID()

    @Test func allFilled() {
        #expect(SeasonCards.order(hasGoal: true, canSetGoal: true, passIds: [a], final: false) == [.calendar, .goal, .recap, .pass(a)])
    }

    @Test func emptiesGoLast() {
        #expect(SeasonCards.order(hasGoal: false, canSetGoal: true, passIds: [a], final: false) == [.calendar, .recap, .pass(a), .goalEmpty])
        #expect(SeasonCards.order(hasGoal: true, canSetGoal: true, passIds: [], final: false) == [.calendar, .goal, .recap, .passEmpty])
        #expect(SeasonCards.order(hasGoal: false, canSetGoal: true, passIds: [], final: false) == [.calendar, .recap, .goalEmpty, .passEmpty])
    }

    @Test func pastSeasonWithoutGoalHasNoGoalCard() {
        #expect(SeasonCards.order(hasGoal: false, canSetGoal: false, passIds: [a], final: false) == [.calendar, .recap, .pass(a)])
    }

    @Test func finalRecapFirst() {
        #expect(SeasonCards.order(hasGoal: true, canSetGoal: false, passIds: [a], final: true) == [.recap, .calendar, .goal, .pass(a)])
    }

    @Test func twoPassesAddTotal() {
        #expect(SeasonCards.order(hasGoal: true, canSetGoal: true, passIds: [a, b], final: false) == [.calendar, .goal, .recap, .pass(a), .pass(b), .passTotal])
    }

    @Test func noVisitsHidesRecap() {
        #expect(SeasonCards.order(hasGoal: false, canSetGoal: true, passIds: [], final: false, hasVisits: false) == [.calendar, .goalEmpty, .passEmpty])
        #expect(SeasonCards.order(hasGoal: true, canSetGoal: true, passIds: [a], final: true, hasVisits: false) == [.calendar, .goal, .pass(a)])
    }
}
