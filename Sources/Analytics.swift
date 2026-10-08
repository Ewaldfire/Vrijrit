import Foundation

struct Metrics {
    var moving = 0.0, stopped = 0.0, unknown = 0.0
    var stops = 0, braking = 0, hardBraking = 0, acceleration = 0, hardAcceleration = 0
    var left = 0, right = 0
    var maxAcceleration = 0.0, maxDeceleration = 0.0, lateralG = 0.0
    var accelerationDate: Date?, decelerationDate: Date?
    var sensorPeak: Double?
    static func calculate(_ trip: Trip) -> Metrics {
        var m = Metrics(); m.sensorPeak = trip.motionPeakG
        var stopStart: Date?, movingBeforeStop = false
        var brakePeak = 0.0, accelPeak = 0.0
        var brakeTime = 0.0, accelTime = 0.0
        var turn = 0.0, turnStart: Date?
        var lastTurnDate = Date.distantPast
        func finishBrake() {
            if brakeTime >= 1 { if brakePeak >= 3 { m.hardBraking += 1 } else { m.braking += 1 } }
            brakePeak = 0; brakeTime = 0
        }
        func finishAccel() {
            if accelTime >= 1 { if accelPeak >= 2.5 { m.hardAcceleration += 1 } else { m.acceleration += 1 } }
            accelPeak = 0; accelTime = 0
        }
        for (a, b) in zip(trip.points, trip.points.dropFirst()) {
            let dt = b.date.timeIntervalSince(a.date)
            guard dt > 0, dt <= 5 else {
                finishBrake(); finishAccel(); turn = 0; turnStart = nil; stopStart = nil
                movingBeforeStop = false
                continue
            }
            if (a.speed + b.speed) / 2 < 0.83 {
                m.stopped += dt
                if stopStart == nil { stopStart = a.date }
            } else {
                m.moving += dt
                if let start = stopStart, a.date.timeIntervalSince(start) >= 5, movingBeforeStop { m.stops += 1 }
                stopStart = nil; movingBeforeStop = true
            }
            let raw = (b.speed - a.speed) / dt
            // Reject implausible GPS spikes; event values are estimates, not pedal presses.
            let value = abs(raw) <= 10 ? raw : 0
            if value > m.maxAcceleration { m.maxAcceleration = value; m.accelerationDate = b.date }
            if -value > m.maxDeceleration { m.maxDeceleration = -value; m.decelerationDate = b.date }
            if value <= -1.2 { brakePeak = max(brakePeak, -value); brakeTime += dt } else { finishBrake() }
            if value >= 1.0 { accelPeak = max(accelPeak, value); accelTime += dt } else { finishAccel() }
            if let h1 = a.course, let h2 = b.course, a.speed >= 3, b.speed >= 3 {
                let angle = (h2 - h1 + 540).truncatingRemainder(dividingBy: 360) - 180
                if abs(angle) / dt < 45 {
                    let lateral = ((a.speed + b.speed) / 2) * abs(angle) * .pi / 180 / dt / 9.80665
                    if lateral < 1.5 { m.lateralG = max(m.lateralG, lateral) }
                    if abs(angle) >= 2 {
                        if turnStart == nil || turn * angle < 0 { turn = 0; turnStart = a.date }
                        turn += angle
                        if let start = turnStart, b.date.timeIntervalSince(start) > 20 { turn = angle; turnStart = a.date }
                        if abs(turn) >= 55 && b.date.timeIntervalSince(lastTurnDate) >= 8 {
                            if turn > 0 { m.right += 1 } else { m.left += 1 }
                            lastTurnDate = b.date; turn = 0; turnStart = nil
                        }
                    } else if let start = turnStart, b.date.timeIntervalSince(start) > 20 { turn = 0; turnStart = nil }
                }
            } else { turn = 0; turnStart = nil }
        }
        finishBrake(); finishAccel()
        if let start = stopStart, let end = trip.points.last?.date, end.timeIntervalSince(start) >= 5, movingBeforeStop { m.stops += 1 }
        m.unknown = max(0, trip.duration - m.moving - m.stopped)
        return m
    }
    mutating func add(_ other: Metrics) {
        moving += other.moving; stopped += other.stopped; unknown += other.unknown
        stops += other.stops; braking += other.braking; hardBraking += other.hardBraking
        acceleration += other.acceleration; hardAcceleration += other.hardAcceleration
        left += other.left; right += other.right
        if other.maxAcceleration > maxAcceleration { maxAcceleration = other.maxAcceleration; accelerationDate = other.accelerationDate }
        if other.maxDeceleration > maxDeceleration { maxDeceleration = other.maxDeceleration; decelerationDate = other.decelerationDate }
        lateralG = max(lateralG, other.lateralG)
        if let peak = other.sensorPeak { sensorPeak = max(sensorPeak ?? 0, peak) }
    }
}

extension Metrics {
    var report: String {
        "Stops: \(stops) • Links: \(left) • Rechts: \(right)\nRemacties: \(braking) normaal / \(hardBraking) stevig\nOptrekken: \(acceleration) normaal / \(hardAcceleration) stevig\nMax versnelling: \(String(format: "%.2f", maxAcceleration)) m/s²\nMax vertraging: \(String(format: "%.2f", maxDeceleration)) m/s²\nGPS-schattingen; sensorwaarden zijn geen gecertificeerde voertuigmetingen."
    }
}
