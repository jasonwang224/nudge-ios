// App's schedulesMatch function is prepended by the build script.
func request(_ phase: Int, id: String = "shared-id", title: String = "Test") -> UNNotificationRequest {
    let content = UNMutableNotificationContent()
    content.title = title
    content.userInfo = ["phase": phase]
    let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(minute: phase * 5, second: 0), repeats: true)
    return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
}
let phases = (0..<12).map { request($0) }
precondition(schedulesMatch(phases.reversed(), phases), "Array order must not matter")
precondition(!schedulesMatch(Array(phases.dropLast()), phases), "A lost phase must fail")
var duplicate = phases; duplicate[11] = phases[0]
precondition(!schedulesMatch(duplicate, phases), "Duplicate phase must not hide a missing one")
var altered = phases; altered[0] = request(0, title: "Changed")
precondition(!schedulesMatch(altered, phases), "Changed content must fail")
var changedID = phases; changedID[0] = request(0, id: "wrong-id")
precondition(!schedulesMatch(changedID, phases), "Changed identity must fail")
let extra = phases + [request(0, id: "unrelated")]
precondition(!schedulesMatch(extra, phases), "Unexpected requests must fail")
let data = try NSKeyedArchiver.archivedData(withRootObject: extra, requiringSecureCoding: true)
let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, UNNotificationRequest.self], from: data) as! [UNNotificationRequest]
precondition(schedulesMatch(decoded, extra), "Secure journal must retain all phases and unrelated requests")
print("Passed: duplicate-ID multiset validation, missing/altered/extra phase rejection, secure archive round-trip.")
