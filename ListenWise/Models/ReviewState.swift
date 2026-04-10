/*
Abstract:
SM-2 spaced repetition review state and scheduling.
*/

import Foundation

/// Per-item review state tracked by the SM-2 scheduler.
struct ReviewState: Codable, Equatable {
    var ef: Double = 2.5
    var interval: Int = 0
    var repetitions: Int = 0
    var dueDate: Date = Date()
    var lastReviewedAt: Date? = nil
    var totalReviews: Int = 0
    var totalLapses: Int = 0
}

/// User's rating of how well they recalled an item.
enum ReviewRating: Int, CaseIterable {
    case again = 0
    case hard = 3
    case good = 4
    case easy = 5

    var label: String {
        switch self {
        case .again: return "Again"
        case .hard:  return "Hard"
        case .good:  return "Good"
        case .easy:  return "Easy"
        }
    }

    var shortcutKey: String {
        switch self {
        case .again: return "1"
        case .hard:  return "2"
        case .good:  return "3"
        case .easy:  return "4"
        }
    }
}

/// A single item pulled from the review queue.
struct ReviewItem: Identifiable {
    enum Kind {
        case word(WordExplanation)
        case sentence(SentenceExplanation)
    }
    let key: String
    let kind: Kind
    let state: ReviewState
    var id: String { key }

    var displayText: String {
        switch kind {
        case .word(let w): return w.word
        case .sentence(let s): return s.sentence
        }
    }
}

/// SM-2 scheduler. Pure function — returns a new state given the current one and a rating.
enum SM2 {
    /// Compute the next state after a review.
    static func schedule(_ state: ReviewState, rating: ReviewRating, now: Date = Date()) -> ReviewState {
        var s = state
        let q = Double(rating.rawValue)

        if rating == .again {
            s.repetitions = 0
            s.interval = 1
            s.totalLapses += 1
        } else {
            switch s.repetitions {
            case 0: s.interval = 1
            case 1: s.interval = 6
            default:
                var factor = s.ef
                if rating == .hard { factor = max(1.2, s.ef * 0.8) }
                if rating == .easy { factor = s.ef * 1.3 }
                s.interval = max(1, Int((Double(s.interval) * factor).rounded()))
            }
            s.repetitions += 1
        }

        // EF update (SM-2 original formula)
        let delta = 0.1 - (5 - q) * (0.08 + (5 - q) * 0.02)
        s.ef = max(1.3, s.ef + delta)

        s.lastReviewedAt = now
        s.dueDate = Calendar.current.date(byAdding: .day, value: s.interval, to: now) ?? now
        s.totalReviews += 1
        return s
    }

    /// Preview the next interval (in days) for each rating — used to label the buttons.
    static func previewIntervals(_ state: ReviewState) -> [ReviewRating: Int] {
        var result: [ReviewRating: Int] = [:]
        for rating in ReviewRating.allCases {
            let next = schedule(state, rating: rating)
            result[rating] = next.interval
        }
        return result
    }
}
