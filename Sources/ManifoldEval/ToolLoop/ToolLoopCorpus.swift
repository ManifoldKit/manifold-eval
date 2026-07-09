import Foundation
import ManifoldInference

/// The tool-loop corpus: a built-in scaffold plus a JSONL file override.
///
/// The built-in corpus lives in Swift (the MTEB `builtinFixture` precedent)
/// rather than a bundled resource: it is code-reviewed alongside the scorer
/// that interprets it, ships with the binary with zero resource-path fuss,
/// and — unlike BFCL/IFEval — has no upstream benchmark to vendor. It is a
/// *scaffold*: honest per-cell threading signal, not a leaderboard-comparable
/// benchmark score.
///
/// Every scripted payload carries **sentinel values** chosen to be absent
/// from model priors for the prompt (`"K97"`, `"ACC-77120"`, `"DEPOT-4Q2"`).
/// The distractor cases go further and script results that *contradict*
/// world knowledge (snow in Cairo) — a model that answers from priors
/// instead of the threaded tool result fails them by construction.
public enum ToolLoopCorpus {

    /// Loads the corpus: the built-in scaffold, or a JSONL file (one
    /// ``ToolLoopCase`` object per line) when `path` is non-nil.
    public static func load(path: String?) throws -> [ToolLoopCase] {
        guard let path else { return builtin }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ToolLoopError.corpusUnreadable(url, underlying: error)
        }
        let decoder = JSONDecoder()
        var cases: [ToolLoopCase] = []
        for rawLine in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let loaded = try decoder.decode(ToolLoopCase.self, from: Data(line.utf8))
            // An expectation-less case would pass vacuously — reject it at
            // the boundary rather than let a typo'd corpus report fake green.
            guard loaded.expect.firstCall != nil
                || loaded.expect.chainedCall != nil
                || !loaded.expect.finalAnswerMustContain.isEmpty else {
                throw ToolLoopError.invalidCase(
                    loaded.id, "specifies no expectation axis — it would pass vacuously"
                )
            }
            cases.append(loaded)
        }
        return cases
    }

    // MARK: - Built-in scaffold

    /// Eight episodes across three probe shapes:
    /// - result → answer (4): one call; the answer must surface a sentinel
    ///   that only exists in the scripted result.
    /// - result → argument chaining (3): the second call's argument must be a
    ///   sentinel from the first call's result — the turn-2 threading probe.
    /// - argument-keyed multi-call (1): the same tool answers twice with
    ///   different sentinels; the answer must surface both.
    public static let builtin: [ToolLoopCase] = [
        // -- result → answer -------------------------------------------------
        ToolLoopCase(
            id: "thread_gate_1",
            userPrompt: "Which gate does flight QF123 depart from? Use the available tools to check, then answer.",
            tools: [
                ScriptedToolSpec(
                    name: "get_flight_status",
                    description: "Look up the live status record for a flight by its flight number.",
                    parameters: objectSchema(["flight": "The flight number, e.g. QF123"], required: ["flight"]),
                    script: ToolScript(result: #"{"flight":"QF123","status":"delayed","gate":"K97"}"#)
                ),
            ],
            expect: ToolLoopExpectations(
                firstCall: ToolLoopExpectedCall(toolName: "get_flight_status", arguments: ["flight": "QF123"]),
                finalAnswerMustContain: ["K97"]
            )
        ),
        ToolLoopCase(
            id: "thread_depot_1",
            userPrompt: "Where is parcel PX-58731 right now? Use the available tools to check, then answer.",
            tools: [
                ScriptedToolSpec(
                    name: "get_parcel_status",
                    description: "Look up the current location record for a parcel by tracking id.",
                    parameters: objectSchema(["tracking_id": "The parcel tracking id"], required: ["tracking_id"]),
                    script: ToolScript(result: #"{"tracking_id":"PX-58731","location":"DEPOT-4Q2","last_scan":"inbound"}"#)
                ),
            ],
            expect: ToolLoopExpectations(
                firstCall: ToolLoopExpectedCall(toolName: "get_parcel_status", arguments: ["tracking_id": "PX-58731"]),
                finalAnswerMustContain: ["DEPOT-4Q2"]
            )
        ),
        ToolLoopCase(
            id: "thread_carrier_1",
            userPrompt: "Which carrier is delivering order 884213? Use the available tools to check, then answer.",
            tools: [
                ScriptedToolSpec(
                    name: "get_order",
                    description: "Fetch the fulfilment record for an order by order id.",
                    parameters: objectSchema(["order_id": "The numeric order id"], required: ["order_id"]),
                    script: ToolScript(result: #"{"order_id":"884213","carrier":"Skyfreight","eta_days":"9"}"#)
                ),
            ],
            expect: ToolLoopExpectations(
                firstCall: ToolLoopExpectedCall(toolName: "get_order", arguments: ["order_id": "884213"]),
                finalAnswerMustContain: ["Skyfreight"]
            )
        ),
        // Distractor: the scripted result contradicts world knowledge. A model
        // answering from priors ("Cairo is hot") instead of the threaded
        // result fails by construction.
        ToolLoopCase(
            id: "thread_distractor_1",
            userPrompt: "What are the current weather conditions in Cairo? Use the available tools to check, then answer with what the tool reports.",
            tools: [
                ScriptedToolSpec(
                    name: "get_current_weather",
                    description: "Get the current observed weather conditions for a city.",
                    parameters: objectSchema(["city": "The city name"], required: ["city"]),
                    script: ToolScript(result: #"{"city":"Cairo","conditions":"snow","temp_c":"-3"}"#)
                ),
            ],
            expect: ToolLoopExpectations(
                firstCall: ToolLoopExpectedCall(toolName: "get_current_weather", arguments: ["city": "Cairo"]),
                finalAnswerMustContain: ["snow"]
            )
        ),
        // -- result → argument chaining --------------------------------------
        ToolLoopCase(
            id: "chain_account_1",
            userPrompt: "What is the current balance for the customer with email sam@example.com? First look up their account, then fetch the balance, then answer.",
            tools: [
                ScriptedToolSpec(
                    name: "lookup_account",
                    description: "Find a customer's account id from their email address.",
                    parameters: objectSchema(["email": "The customer's email address"], required: ["email"]),
                    script: ToolScript(result: #"{"account_id":"ACC-77120"}"#)
                ),
                // Gated on the sentinel: any other argument gets an error
                // payload, exactly as a real API would. This is load-bearing
                // twice over — the sentinel (and the balance) must not leak
                // to an episode that never threaded it, and a broken chain
                // must produce a visibly broken answer, not a lucky one.
                ScriptedToolSpec(
                    name: "get_balance",
                    description: "Fetch the current balance for an account by account id.",
                    parameters: objectSchema(["account_id": "The account id, e.g. ACC-12345"], required: ["account_id"]),
                    script: ToolScript(
                        result: #"{"error":"unknown account_id"}"#,
                        argumentKey: "account_id",
                        resultsByArgument: [
                            "ACC-77120": #"{"account_id":"ACC-77120","balance":"482.15","currency":"AUD"}"#,
                        ]
                    )
                ),
            ],
            expect: ToolLoopExpectations(
                firstCall: ToolLoopExpectedCall(toolName: "lookup_account", arguments: ["email": "sam@example.com"]),
                chainedCall: ToolLoopChainedCall(
                    toolName: "get_balance", argumentKey: "account_id", expectedValue: "ACC-77120"
                ),
                finalAnswerMustContain: ["482.15"]
            )
        ),
        ToolLoopCase(
            id: "chain_booking_1",
            userPrompt: "Which seat is Rory Ford booked in? First find the booking reference, then fetch the seat for that booking, then answer.",
            tools: [
                ScriptedToolSpec(
                    name: "find_booking",
                    description: "Find a passenger's booking reference from their full name.",
                    parameters: objectSchema(["name": "The passenger's full name"], required: ["name"]),
                    script: ToolScript(result: #"{"booking_ref":"ZXQ-9917"}"#)
                ),
                // Sentinel-gated — see get_balance above.
                ScriptedToolSpec(
                    name: "get_seat",
                    description: "Fetch the seat assignment for a booking by booking reference.",
                    parameters: objectSchema(["booking_ref": "The booking reference, e.g. ABC-1234"], required: ["booking_ref"]),
                    script: ToolScript(
                        result: #"{"error":"unknown booking_ref"}"#,
                        argumentKey: "booking_ref",
                        resultsByArgument: [
                            "ZXQ-9917": #"{"booking_ref":"ZXQ-9917","seat":"41F"}"#,
                        ]
                    )
                ),
            ],
            expect: ToolLoopExpectations(
                firstCall: ToolLoopExpectedCall(toolName: "find_booking"),
                chainedCall: ToolLoopChainedCall(
                    toolName: "get_seat", argumentKey: "booking_ref", expectedValue: "ZXQ-9917"
                ),
                finalAnswerMustContain: ["41F"]
            )
        ),
        ToolLoopCase(
            id: "chain_forecast_1",
            userPrompt: "What is tomorrow's forecast where user rory is located? First look up the user's city, then fetch that city's forecast, then answer.",
            tools: [
                ScriptedToolSpec(
                    name: "get_user_location",
                    description: "Look up the registered home city for a user by username.",
                    parameters: objectSchema(["user": "The username"], required: ["user"]),
                    script: ToolScript(result: #"{"user":"rory","city":"Wagga Wagga"}"#)
                ),
                // Sentinel-gated — see get_balance above.
                ScriptedToolSpec(
                    name: "get_forecast",
                    description: "Fetch tomorrow's weather forecast for a city.",
                    parameters: objectSchema(["city": "The city name"], required: ["city"]),
                    script: ToolScript(
                        result: #"{"error":"unknown city"}"#,
                        argumentKey: "city",
                        resultsByArgument: [
                            "Wagga Wagga": #"{"city":"Wagga Wagga","forecast":"hail","high_c":"7"}"#,
                        ]
                    )
                ),
            ],
            expect: ToolLoopExpectations(
                firstCall: ToolLoopExpectedCall(toolName: "get_user_location", arguments: ["user": "rory"]),
                chainedCall: ToolLoopChainedCall(
                    toolName: "get_forecast", argumentKey: "city", expectedValue: "Wagga Wagga"
                ),
                finalAnswerMustContain: ["hail"]
            )
        ),
        // -- argument-keyed multi-call ----------------------------------------
        ToolLoopCase(
            id: "multi_quote_1",
            userPrompt: "Get quotes for the stock symbols NVAX and BLZR, and report both prices in your answer.",
            tools: [
                ScriptedToolSpec(
                    name: "get_stock_quote",
                    description: "Get the latest trade price for a stock by ticker symbol.",
                    parameters: objectSchema(["symbol": "The ticker symbol, e.g. NVAX"], required: ["symbol"]),
                    script: ToolScript(
                        result: #"{"error":"unknown symbol"}"#,
                        argumentKey: "symbol",
                        resultsByArgument: [
                            "NVAX": #"{"symbol":"NVAX","price":"217.44"}"#,
                            "BLZR": #"{"symbol":"BLZR","price":"63.02"}"#,
                        ]
                    )
                ),
            ],
            expect: ToolLoopExpectations(
                firstCall: ToolLoopExpectedCall(toolName: "get_stock_quote"),
                finalAnswerMustContain: ["217.44", "63.02"]
            )
        ),
    ]

    /// Builds a flat JSON-Schema object with string-typed properties — the
    /// only shape the scaffold corpus needs.
    static func objectSchema(
        _ properties: [String: String],
        required: [String]
    ) -> JSONSchemaValue {
        var props: [String: JSONSchemaValue] = [:]
        for (name, description) in properties {
            props[name] = .object([
                "type": .string("string"),
                "description": .string(description),
            ])
        }
        return .object([
            "type": .string("object"),
            "properties": .object(props),
            "required": .array(required.map { .string($0) }),
        ])
    }
}
