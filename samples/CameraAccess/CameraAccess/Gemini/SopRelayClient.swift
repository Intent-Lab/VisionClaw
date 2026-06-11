import Foundation

private extension KeyedDecodingContainer {
  func decodeFirstString(forKeys keys: [K]) throws -> String? {
    for key in keys {
      if let stringValue = try decodeIfPresent(String.self, forKey: key),
         !stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return stringValue
      }
    }
    return nil
  }

  func decodeLossyInt(forKeys keys: [K]) throws -> Int? {
    for key in keys {
      if let intValue = try? decodeIfPresent(Int.self, forKey: key) {
        return intValue
      }
      if let stringValue = try? decodeIfPresent(String.self, forKey: key),
         !stringValue.isEmpty {
        if let intValue = Int(stringValue) {
          return intValue
        }
        if let doubleValue = Double(stringValue) {
          return Int(doubleValue.rounded(.down))
        }
      }
      if let doubleValue = try? decodeIfPresent(Double.self, forKey: key) {
        return Int(doubleValue.rounded(.down))
      }
    }
    return nil
  }

  func decodeLossyBool(forKeys keys: [K]) throws -> Bool? {
    for key in keys {
      if let boolValue = try? decodeIfPresent(Bool.self, forKey: key) {
        return boolValue
      }
      if let intValue = try? decodeIfPresent(Int.self, forKey: key) {
        return intValue != 0
      }
      if let stringValue = try? decodeIfPresent(String.self, forKey: key),
         !stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        switch stringValue.lowercased() {
        case "true", "1", "yes", "active":
          return true
        case "false", "0", "no", "inactive":
          return false
        default:
          continue
        }
      }
    }
    return nil
  }

  func decodeLossyString(forKeys keys: [K]) throws -> String? {
    for key in keys {
      if let stringValue = try? decodeIfPresent(String.self, forKey: key) {
        let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          return trimmed
        }
      }
      if let intValue = try? decodeIfPresent(Int.self, forKey: key) {
        return String(intValue)
      }
      if let doubleValue = try? decodeIfPresent(Double.self, forKey: key) {
        if doubleValue.rounded(.towardZero) == doubleValue {
          return String(Int(doubleValue))
        }
        return String(doubleValue)
      }
      if let boolValue = try? decodeIfPresent(Bool.self, forKey: key) {
        return boolValue ? "true" : "false"
      }
    }
    return nil
  }
}

private func canonicalLucasSopTitle(for sopID: String) -> String? {
  switch sopID {
  case "22222222-2222-2222-2222-222222222222":
    return "Cold Chain Verification SOP"
  case "a1000001-0000-0000-0000-000000000001":
    return "Burger Assembly"
  case "a1000002-0000-0000-0000-000000000002":
    return "Fries Assembly"
  case "a1000003-0000-0000-0000-000000000003":
    return "Drink Prep"
  default:
    return nil
  }
}

private func canonicalLucasPackageTitle(for packageID: String?) -> String? {
  guard let packageID else { return nil }
  switch packageID {
  case "33333333-3333-3333-3333-333333333333":
    return "Inbound Cold Chain Audit"
  case "b2000001-0000-0000-0000-000000000001":
    return "QSR Value Meal Order"
  default:
    return nil
  }
}

private func canonicalLucasSopSortOrder(for sopID: String) -> Int? {
  switch sopID {
  case "22222222-2222-2222-2222-222222222222":
    return 1
  case "a1000001-0000-0000-0000-000000000001":
    return 2
  case "a1000002-0000-0000-0000-000000000002":
    return 3
  case "a1000003-0000-0000-0000-000000000003":
    return 4
  default:
    return nil
  }
}

struct BackendWorker: Identifiable, Decodable, Equatable {
  let id: String
  let loginCode: String?
  let email: String?
  let displayName: String
  let role: String?
  let status: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case loginCode = "login_code"
    case loginCodeCamel = "loginCode"
    case email
    case displayName = "display_name"
    case displayNameCamel = "displayName"
    case name
    case role
    case status
    case active
  }

  init(
    id: String,
    loginCode: String?,
    email: String? = nil,
    displayName: String,
    role: String?,
    status: String?
  ) {
    self.id = id
    self.loginCode = loginCode
    self.email = email
    self.displayName = displayName
    self.role = role
    self.status = status
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    loginCode = try container.decodeFirstString(forKeys: [.loginCode, .loginCodeCamel])
    email = try container.decodeIfPresent(String.self, forKey: .email)
    displayName =
      try container.decodeFirstString(forKeys: [.displayName, .displayNameCamel, .name])
      ?? "Unassigned Worker"
    role = try container.decodeIfPresent(String.self, forKey: .role)
    status =
      try container.decodeIfPresent(String.self, forKey: .status)
      ?? ((try container.decodeLossyBool(forKeys: [.active]) ?? false) ? "active" : nil)
  }
}

struct BackendDevice: Identifiable, Decodable, Equatable {
  let id: String
  let workerID: String?
  let platform: String?
  let deviceLabel: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case workerID = "worker_id"
    case workerIDCamel = "workerId"
    case platform
    case deviceLabel = "device_label"
    case deviceLabelCamel = "deviceLabel"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    workerID = try container.decodeFirstString(forKeys: [.workerID, .workerIDCamel])
    platform = try container.decodeIfPresent(String.self, forKey: .platform)
    deviceLabel = try container.decodeFirstString(forKeys: [.deviceLabel, .deviceLabelCamel])
  }
}

struct BackendPackage: Identifiable, Decodable, Equatable {
  let id: String
  let title: String
  let description: String?
  let outcome: String?
  let version: Int?
  let status: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case name
    case description
    case outcome
    case version
    case status
  }

  init(
    id: String,
    title: String,
    description: String?,
    outcome: String?,
    version: Int?,
    status: String?
  ) {
    self.id = id
    self.title = title
    self.description = description
    self.outcome = outcome
    self.version = version
    self.status = status
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    title =
      try container.decodeIfPresent(String.self, forKey: .title)
      ?? container.decodeIfPresent(String.self, forKey: .name)
      ?? "Untitled Package"
    description = try container.decodeIfPresent(String.self, forKey: .description)
    outcome = try container.decodeIfPresent(String.self, forKey: .outcome)
    version = try container.decodeLossyInt(forKeys: [.version])
    status = try container.decodeIfPresent(String.self, forKey: .status)
  }
}

struct BackendAssignedPackage: Identifiable, Decodable, Equatable {
  let id: String
  let title: String
  let description: String?
  let outcome: String?
  let version: Int?
  let shiftName: String?
  let active: Bool?
  let packageRunID: String?
  let packageRunStatus: String?
  let packageRunStartedAt: String?
  let packageRunCompletedAt: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case packageID = "package_id"
    case packageIDCamel = "packageId"
    case title
    case packageTitle = "package_title"
    case packageTitleCamel = "packageTitle"
    case description
    case packageDescription = "package_description"
    case packageDescriptionCamel = "packageDescription"
    case outcome
    case packageOutcome = "package_outcome"
    case packageOutcomeCamel = "packageOutcome"
    case version
    case packageVersion = "package_version"
    case packageVersionCamel = "packageVersion"
    case shiftName = "shift_name"
    case shiftNameCamel = "shiftName"
    case active
    case packageRunID = "package_run_id"
    case packageRunIDCamel = "packageRunId"
    case packageRunStatus = "package_run_status"
    case packageRunStatusCamel = "packageRunStatus"
    case packageRunStartedAt = "package_run_started_at"
    case packageRunStartedAtCamel = "packageRunStartedAt"
    case packageRunCompletedAt = "package_run_completed_at"
    case packageRunCompletedAtCamel = "packageRunCompletedAt"
  }

  init(
    id: String,
    title: String,
    description: String?,
    outcome: String?,
    version: Int?,
    shiftName: String?,
    active: Bool?,
    packageRunID: String?,
    packageRunStatus: String?,
    packageRunStartedAt: String?,
    packageRunCompletedAt: String?
  ) {
    self.id = id
    self.title = title
    self.description = description
    self.outcome = outcome
    self.version = version
    self.shiftName = shiftName
    self.active = active
    self.packageRunID = packageRunID
    self.packageRunStatus = packageRunStatus
    self.packageRunStartedAt = packageRunStartedAt
    self.packageRunCompletedAt = packageRunCompletedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawID =
      try container.decodeFirstString(forKeys: [.id, .packageID, .packageIDCamel])
      ?? UUID().uuidString
    let rawTitle =
      try container.decodeFirstString(forKeys: [.title, .packageTitle, .packageTitleCamel])
      ?? canonicalLucasPackageTitle(for: rawID)
      ?? "Untitled Package"

    self.init(
      id: rawID,
      title: rawTitle,
      description: try container.decodeFirstString(forKeys: [.description, .packageDescription, .packageDescriptionCamel]),
      outcome: try container.decodeFirstString(forKeys: [.outcome, .packageOutcome, .packageOutcomeCamel]),
      version: try container.decodeLossyInt(forKeys: [.version, .packageVersion, .packageVersionCamel]),
      shiftName: try container.decodeFirstString(forKeys: [.shiftName, .shiftNameCamel]),
      active: try container.decodeLossyBool(forKeys: [.active]),
      packageRunID: try container.decodeFirstString(forKeys: [.packageRunID, .packageRunIDCamel]),
      packageRunStatus: try container.decodeFirstString(forKeys: [.packageRunStatus, .packageRunStatusCamel]),
      packageRunStartedAt: try container.decodeFirstString(forKeys: [.packageRunStartedAt, .packageRunStartedAtCamel]),
      packageRunCompletedAt: try container.decodeFirstString(forKeys: [.packageRunCompletedAt, .packageRunCompletedAtCamel])
    )
  }
}

struct BackendShift: Identifiable, Decodable, Equatable {
  let id: String
  let packageID: String?
  let shiftName: String?
  let startsAt: String?
  let endsAt: String?
  let active: Bool?
  let package: BackendPackage?

  private enum CodingKeys: String, CodingKey {
    case id
    case packageID = "package_id"
    case packageIDCamel = "packageId"
    case shiftName = "shift_name"
    case shiftNameCamel = "shiftName"
    case startsAt = "starts_at"
    case startsAtCamel = "startsAt"
    case endsAt = "ends_at"
    case endsAtCamel = "endsAt"
    case active
    case package
  }

  init(
    id: String,
    packageID: String?,
    shiftName: String?,
    startsAt: String?,
    endsAt: String?,
    active: Bool?,
    package: BackendPackage?
  ) {
    self.id = id
    self.packageID = packageID
    self.shiftName = shiftName
    self.startsAt = startsAt
    self.endsAt = endsAt
    self.active = active
    self.package = package
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    packageID = try container.decodeFirstString(forKeys: [.packageID, .packageIDCamel])
    shiftName = try container.decodeFirstString(forKeys: [.shiftName, .shiftNameCamel])
    startsAt = try container.decodeFirstString(forKeys: [.startsAt, .startsAtCamel])
    endsAt = try container.decodeFirstString(forKeys: [.endsAt, .endsAtCamel])
    active = try container.decodeLossyBool(forKeys: [.active])
    package = try container.decodeIfPresent(BackendPackage.self, forKey: .package)
  }
}

struct WorkerQueueStep: Identifiable, Decodable, Equatable, Hashable {
  let id: String
  let order: Int
  let title: String
  let description: String
  let duration: String
  let validation: String
  let critical: Bool
  let aiPrompt: String
  let expectedObjects: [String]
  let preconditions: [String]
  let postconditions: [String]
  let skipRisk: String
  let evidenceRequired: Bool
  let allowManualComplete: Bool

  private enum CodingKeys: String, CodingKey {
    case id
    case order
    case name
    case title
    case label
    case step
    case item
    case index
    case description
    case instruction
    case duration
    case validation
    case critical
    case aiPrompt = "ai_prompt"
    case aiPromptCamel = "aiPrompt"
    case expectedObjects = "expected_objects"
    case expectedObjectsCamel = "expectedObjects"
    case preconditions
    case postconditions
    case skipRisk = "skip_risk"
    case skipRiskCamel = "skipRisk"
    case evidenceRequired = "evidence_required"
    case evidenceRequiredCamel = "evidenceRequired"
    case allowManualComplete = "allow_manual_complete"
    case allowManualCompleteCamel = "allowManualComplete"
  }

  init(
    id: String,
    order: Int,
    title: String,
    description: String = "",
    duration: String = "30s",
    validation: String = "visual",
    critical: Bool = false,
    aiPrompt: String? = nil,
    expectedObjects: [String] = [],
    preconditions: [String] = [],
    postconditions: [String] = [],
    skipRisk: String = "medium",
    evidenceRequired: Bool = true,
    allowManualComplete: Bool = true
  ) {
    self.id = id
    self.order = order
    self.title = title
    self.description = description
    self.duration = duration
    self.validation = validation
    self.critical = critical
    self.aiPrompt = aiPrompt ?? "Look at the image and confirm whether \"\(title)\" has been completed."
    self.expectedObjects = expectedObjects
    self.preconditions = preconditions
    self.postconditions = postconditions
    self.skipRisk = skipRisk
    self.evidenceRequired = evidenceRequired
    self.allowManualComplete = allowManualComplete
  }

  init(from decoder: Decoder) throws {
    if let single = try? decoder.singleValueContainer(),
       let raw = try? single.decode(String.self) {
      self.init(
        id: raw.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression),
        order: 0,
        title: raw
      )
      return
    }

    let container = try decoder.container(keyedBy: CodingKeys.self)
    let name = try container.decodeLossyString(forKeys: [.name])
    let fallbackTitle = try container.decodeLossyString(forKeys: [.title])
    let label = try container.decodeLossyString(forKeys: [.label])
    let step = try container.decodeLossyString(forKeys: [.step])
    let item = try container.decodeLossyString(forKeys: [.item])
    let resolvedTitle = name ?? fallbackTitle ?? label ?? step ?? item ?? "Untitled Step"
    let resolvedID =
      try container.decodeLossyString(forKeys: [.id])
      ?? resolvedTitle.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
    let expectedObjects =
      try container.decodeIfPresent([String].self, forKey: .expectedObjects)
      ?? container.decodeIfPresent([String].self, forKey: .expectedObjectsCamel)
      ?? []
    let preconditions = (try container.decodeIfPresent([String].self, forKey: .preconditions)) ?? []
    let postconditions = (try container.decodeIfPresent([String].self, forKey: .postconditions)) ?? []
    let skipRisk =
      try container.decodeLossyString(forKeys: [.skipRisk, .skipRiskCamel])
      ?? ((try container.decodeLossyBool(forKeys: [.critical]) ?? false) ? "high" : "medium")
    self.init(
      id: resolvedID,
      order: try container.decodeLossyInt(forKeys: [.order, .index]) ?? 0,
      title: resolvedTitle,
      description: try container.decodeLossyString(forKeys: [.description, .instruction]) ?? "",
      duration: try container.decodeLossyString(forKeys: [.duration]) ?? "30s",
      validation: try container.decodeLossyString(forKeys: [.validation]) ?? "visual",
      critical: try container.decodeLossyBool(forKeys: [.critical]) ?? false,
      aiPrompt:
        try container.decodeLossyString(forKeys: [.aiPrompt, .aiPromptCamel]),
      expectedObjects: expectedObjects.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
      preconditions: preconditions.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
      postconditions: postconditions.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
      skipRisk: ["low", "medium", "high"].contains(skipRisk) ? skipRisk : "medium",
      evidenceRequired:
        try container.decodeLossyBool(forKeys: [.evidenceRequired, .evidenceRequiredCamel])
        ?? true,
      allowManualComplete:
        try container.decodeLossyBool(forKeys: [.allowManualComplete, .allowManualCompleteCamel])
        ?? true
    )
  }
}

struct WorkerQueueItem: Identifiable, Decodable, Equatable {
  let shiftAssignmentID: String?
  let workerID: String?
  let workerName: String?
  let packageID: String?
  let packageTitle: String?
  let packageRunID: String?
  let packageVersion: Int?
  let sopID: String
  let sopTitle: String
  let sopVersion: Int?
  let steps: [WorkerQueueStep]
  let shiftName: String?
  let sourceType: String
  let sortOrder: Int
  let required: Bool
  let active: Bool?
  let startsAt: String?
  let endsAt: String?

  var id: String { "\(packageRunID ?? packageID ?? sourceType):\(sopID)" }
  var stepTitles: [String] { steps.map(\.title) }

  private enum CodingKeys: String, CodingKey {
    case shiftAssignmentID = "shift_assignment_id"
    case shiftAssignmentIDCamel = "shiftAssignmentId"
    case workerID = "worker_id"
    case workerIDCamel = "workerId"
    case workerName = "worker_name"
    case workerNameCamel = "workerName"
    case packageID = "package_id"
    case packageIDCamel = "packageId"
    case packageTitle = "package_title"
    case packageTitleCamel = "packageTitle"
    case packageRunID = "package_run_id"
    case packageRunIDCamel = "packageRunId"
    case packageVersion = "package_version"
    case packageVersionCamel = "packageVersion"
    case sopID = "sop_id"
    case sopIDCamel = "sopId"
    case sopTitle = "sop_title"
    case sopTitleCamel = "sopTitle"
    case sopVersion = "sop_version"
    case sopVersionCamel = "sopVersion"
    case steps
    case shiftName = "shift_name"
    case shiftNameCamel = "shiftName"
    case sourceType = "source_type"
    case sourceTypeCamel = "sourceType"
    case sortOrder = "sort_order"
    case sortOrderCamel = "sortOrder"
    case required
    case active
    case startsAt = "starts_at"
    case startsAtCamel = "startsAt"
    case scheduledFor = "scheduledFor"
    case endsAt = "ends_at"
    case endsAtCamel = "endsAt"
    case completedAtCamel = "completedAt"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard let decodedSopID = try container.decodeFirstString(forKeys: [.sopID, .sopIDCamel]) else {
      throw DecodingError.keyNotFound(
        CodingKeys.sopID,
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "Missing sop_id/sopId in worker queue item."
        )
      )
    }
    shiftAssignmentID = try container.decodeFirstString(forKeys: [.shiftAssignmentID, .shiftAssignmentIDCamel])
    workerID = try container.decodeFirstString(forKeys: [.workerID, .workerIDCamel])
    workerName = try container.decodeFirstString(forKeys: [.workerName, .workerNameCamel])
    packageID = try container.decodeFirstString(forKeys: [.packageID, .packageIDCamel])
    packageTitle =
      try container.decodeFirstString(forKeys: [.packageTitle, .packageTitleCamel])
      ?? canonicalLucasPackageTitle(for: packageID)
    packageRunID = try container.decodeFirstString(forKeys: [.packageRunID, .packageRunIDCamel])
    packageVersion = try container.decodeLossyInt(forKeys: [.packageVersion, .packageVersionCamel])
    sopID = decodedSopID
    sopTitle =
      try container.decodeFirstString(forKeys: [.sopTitle, .sopTitleCamel])
      ?? canonicalLucasSopTitle(for: decodedSopID)
      ?? "Assigned SOP"
    sopVersion = try container.decodeLossyInt(forKeys: [.sopVersion, .sopVersionCamel])
    shiftName =
      try container.decodeFirstString(forKeys: [.shiftName, .shiftNameCamel])
      ?? "Morning"
    sourceType =
      try container.decodeFirstString(forKeys: [.sourceType, .sourceTypeCamel])
      ?? (packageID == nil ? "standalone" : "package")
    sortOrder =
      try container.decodeLossyInt(forKeys: [.sortOrder, .sortOrderCamel])
      ?? canonicalLucasSopSortOrder(for: decodedSopID)
      ?? 0
    required = try container.decodeLossyBool(forKeys: [.required]) ?? true
    active = try container.decodeLossyBool(forKeys: [.active])
    startsAt = try container.decodeFirstString(forKeys: [.startsAt, .startsAtCamel, .scheduledFor])
    endsAt = try container.decodeFirstString(forKeys: [.endsAt, .endsAtCamel, .completedAtCamel])

    if let direct = try? container.decodeIfPresent([String].self, forKey: .steps) {
      steps = direct.enumerated().map { index, title in
        WorkerQueueStep(
          id: "\(decodedSopID)-\(index + 1)",
          order: index + 1,
          title: title
        )
      }
    } else if let richSteps = try container.decodeIfPresent([WorkerQueueStep].self, forKey: .steps) {
      steps = richSteps.enumerated().map { index, step in
        WorkerQueueStep(
          id: step.id,
          order: step.order == 0 ? index + 1 : step.order,
          title: step.title,
          description: step.description,
          duration: step.duration,
          validation: step.validation,
          critical: step.critical,
          aiPrompt: step.aiPrompt,
          expectedObjects: step.expectedObjects,
          preconditions: step.preconditions,
          postconditions: step.postconditions,
          skipRisk: step.skipRisk,
          evidenceRequired: step.evidenceRequired,
          allowManualComplete: step.allowManualComplete
        )
      }
    } else {
      steps = []
    }
  }
}

struct BootstrapPayload: Decodable, Equatable {
  let worker: BackendWorker
  let device: BackendDevice?
  let shift: BackendShift?
  let queue: [WorkerQueueItem]
  let assignedPackages: [BackendAssignedPackage]
  let workerSessionToken: String?
  let workerSessionExpiresAt: String?

  private enum CodingKeys: String, CodingKey {
    case worker
    case device
    case shift
    case queue
    case assignedPackages = "assigned_packages"
    case assignedPackagesCamel = "assignedPackages"
    case packages
    case workerSessionToken = "worker_session_token"
    case workerSessionTokenCamel = "workerSessionToken"
    case workerToken = "worker_token"
    case sessionToken = "session_token"
    case sessionTokenCamel = "sessionToken"
    case token
    case workerSessionExpiresAt = "worker_session_expires_at"
    case workerSessionExpiresAtCamel = "workerSessionExpiresAt"
    case sessionExpiresAt = "session_expires_at"
    case sessionExpiresAtCamel = "sessionExpiresAt"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    worker = try container.decode(BackendWorker.self, forKey: .worker)
    device = try container.decodeIfPresent(BackendDevice.self, forKey: .device)
    shift = try container.decodeIfPresent(BackendShift.self, forKey: .shift)
    queue = try container.decodeIfPresent([WorkerQueueItem].self, forKey: .queue) ?? []
    let directAssignedPackages =
      try container.decodeIfPresent([BackendAssignedPackage].self, forKey: .assignedPackages)
    let camelAssignedPackages =
      try container.decodeIfPresent([BackendAssignedPackage].self, forKey: .assignedPackagesCamel)
    let packageList =
      try container.decodeIfPresent([BackendAssignedPackage].self, forKey: .packages)
    assignedPackages =
      directAssignedPackages
      ?? camelAssignedPackages
      ?? packageList
      ?? BootstrapPayload.deriveAssignedPackages(shift: shift, queue: queue)

    let tokenFromWorkerSession =
      try container.decodeIfPresent(String.self, forKey: .workerSessionToken)
    let tokenFromWorkerSessionCamel =
      try container.decodeIfPresent(String.self, forKey: .workerSessionTokenCamel)
    let tokenFromWorkerToken =
      try container.decodeIfPresent(String.self, forKey: .workerToken)
    let tokenFromSession =
      try container.decodeIfPresent(String.self, forKey: .sessionToken)
    let tokenFromSessionCamel =
      try container.decodeIfPresent(String.self, forKey: .sessionTokenCamel)
    let tokenFromGeneric =
      try container.decodeIfPresent(String.self, forKey: .token)
    workerSessionToken =
      tokenFromWorkerSession
      ?? tokenFromWorkerSessionCamel
      ?? tokenFromWorkerToken
      ?? tokenFromSession
      ?? tokenFromSessionCamel
      ?? tokenFromGeneric

    let expiresFromWorkerSession =
      try container.decodeIfPresent(String.self, forKey: .workerSessionExpiresAt)
    let expiresFromSession =
      try container.decodeIfPresent(String.self, forKey: .sessionExpiresAt)
    let expiresFromWorkerSessionCamel =
      try container.decodeIfPresent(String.self, forKey: .workerSessionExpiresAtCamel)
    let expiresFromSessionCamel =
      try container.decodeIfPresent(String.self, forKey: .sessionExpiresAtCamel)
    workerSessionExpiresAt =
      expiresFromWorkerSession
      ?? expiresFromSession
      ?? expiresFromWorkerSessionCamel
      ?? expiresFromSessionCamel
  }

  private static func deriveAssignedPackages(
    shift: BackendShift?,
    queue: [WorkerQueueItem]
  ) -> [BackendAssignedPackage] {
    var resolved: [BackendAssignedPackage] = []
    var seen = Set<String>()

    if let package = shift?.package {
      let candidate = BackendAssignedPackage(
        id: package.id,
        title: package.title,
        description: package.description,
        outcome: package.outcome,
        version: package.version,
        shiftName: shift?.shiftName,
        active: shift?.active,
        packageRunID: queue.first(where: { $0.packageID == package.id })?.packageRunID,
        packageRunStatus: nil,
        packageRunStartedAt: nil,
        packageRunCompletedAt: nil
      )
      resolved.append(candidate)
      seen.insert(candidate.id)
    }

    for item in queue where item.packageID != nil {
      guard let packageID = item.packageID, !seen.contains(packageID) else { continue }
      resolved.append(
        BackendAssignedPackage(
          id: packageID,
          title: item.packageTitle ?? "Assigned Package",
          description: nil,
          outcome: nil,
          version: item.packageVersion,
          shiftName: item.shiftName ?? shift?.shiftName,
          active: item.active,
          packageRunID: item.packageRunID,
          packageRunStatus: nil,
          packageRunStartedAt: item.startsAt,
          packageRunCompletedAt: item.endsAt
        )
      )
      seen.insert(packageID)
    }

    return resolved
  }
}

struct BackendExecutionSession: Identifiable, Decodable, Equatable {
  let id: String
  let workerID: String?
  let deviceID: String?
  let packageID: String?
  let packageRunID: String?
  let currentSopID: String?
  let sopVersion: Int?
  let packageVersion: Int?
  let currentStepIndex: Int
  let status: String
  let helpRequested: Bool
  let webrtcRoomCode: String?
  let lastFrameBucket: String?
  let lastFramePath: String?
  let startedAt: String?
  let endedAt: String?
  let updatedAt: String?
  let packageProgressWarning: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case workerID = "worker_id"
    case workerIDCamel = "workerId"
    case deviceID = "device_id"
    case deviceIDCamel = "deviceId"
    case packageID = "package_id"
    case packageIDCamel = "packageId"
    case packageRunID = "package_run_id"
    case packageRunIDCamel = "packageRunId"
    case currentSopID = "current_sop_id"
    case currentSopIDCamel = "currentSopId"
    case sopVersion = "sop_version"
    case sopVersionCamel = "sopVersion"
    case packageVersion = "package_version"
    case packageVersionCamel = "packageVersion"
    case currentStepIndex = "current_step_index"
    case currentStepIndexCamel = "currentStepIndex"
    case status
    case helpRequested = "help_requested"
    case helpRequestedCamel = "helpRequested"
    case webrtcRoomCode = "webrtc_room_code"
    case webrtcRoomCodeCamel = "webrtcRoomCode"
    case lastFrameBucket = "last_frame_bucket"
    case lastFrameBucketCamel = "lastFrameBucket"
    case lastFramePath = "last_frame_path"
    case lastFramePathCamel = "lastFramePath"
    case startedAt = "started_at"
    case startedAtCamel = "startedAt"
    case endedAt = "ended_at"
    case endedAtCamel = "endedAt"
    case updatedAt = "updated_at"
    case updatedAtCamel = "updatedAt"
    case packageProgressWarning = "package_progress_warning"
    case packageProgressWarningCamel = "packageProgressWarning"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    workerID = try container.decodeFirstString(forKeys: [.workerID, .workerIDCamel])
    deviceID = try container.decodeFirstString(forKeys: [.deviceID, .deviceIDCamel])
    packageID = try container.decodeFirstString(forKeys: [.packageID, .packageIDCamel])
    packageRunID = try container.decodeFirstString(forKeys: [.packageRunID, .packageRunIDCamel])
    currentSopID = try container.decodeFirstString(forKeys: [.currentSopID, .currentSopIDCamel])
    sopVersion = try container.decodeLossyInt(forKeys: [.sopVersion, .sopVersionCamel])
    packageVersion = try container.decodeLossyInt(forKeys: [.packageVersion, .packageVersionCamel])
    currentStepIndex = try container.decodeLossyInt(forKeys: [.currentStepIndex, .currentStepIndexCamel]) ?? 0
    status = try container.decodeIfPresent(String.self, forKey: .status) ?? "active"
    helpRequested = try container.decodeLossyBool(forKeys: [.helpRequested, .helpRequestedCamel]) ?? false
    webrtcRoomCode = try container.decodeFirstString(forKeys: [.webrtcRoomCode, .webrtcRoomCodeCamel])
    lastFrameBucket = try container.decodeFirstString(forKeys: [.lastFrameBucket, .lastFrameBucketCamel])
    lastFramePath = try container.decodeFirstString(forKeys: [.lastFramePath, .lastFramePathCamel])
    startedAt = try container.decodeFirstString(forKeys: [.startedAt, .startedAtCamel])
    endedAt = try container.decodeFirstString(forKeys: [.endedAt, .endedAtCamel])
    updatedAt = try container.decodeFirstString(forKeys: [.updatedAt, .updatedAtCamel])
    packageProgressWarning = try container.decodeFirstString(
      forKeys: [.packageProgressWarning, .packageProgressWarningCamel]
    )
  }
}

struct BackendExecutionEvent: Identifiable, Decodable, Equatable {
  let id: String
  let sessionID: String?
  let eventType: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case sessionID = "session_id"
    case sessionIDCamel = "sessionId"
    case eventType = "event_type"
    case eventTypeCamel = "eventType"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeLossyString(forKeys: [.id]) ?? UUID().uuidString
    sessionID = try container.decodeFirstString(forKeys: [.sessionID, .sessionIDCamel])
    eventType = try container.decodeFirstString(forKeys: [.eventType, .eventTypeCamel])
  }
}

struct BackendIntervention: Identifiable, Decodable, Equatable {
  let id: String
  let sessionID: String?
  let status: String?
  let notes: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case sessionID = "session_id"
    case status
    case notes
  }
}

struct BackendMediaAsset: Identifiable, Decodable, Equatable {
  let id: String
  let sessionID: String?
  let bucket: String?
  let path: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case sessionID = "session_id"
    case bucket
    case path
  }
}

struct BackendMediaUploadTarget: Decodable, Equatable {
  let assetID: String?
  let uploadURL: String
  let method: String
  let headers: [String: String]

  private enum CodingKeys: String, CodingKey {
    case assetID = "asset_id"
    case assetIDCamel = "assetId"
    case uploadURL = "upload_url"
    case uploadURLCamel = "uploadUrl"
    case method
    case headers
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    assetID = try container.decodeFirstString(forKeys: [.assetID, .assetIDCamel])
    uploadURL = try container.decodeFirstString(forKeys: [.uploadURL, .uploadURLCamel]) ?? ""
    method = try container.decodeIfPresent(String.self, forKey: .method) ?? "PUT"
    headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
  }
}

struct WorkerTelemetryEvent: @unchecked Sendable {
  let name: String
  let source: String
  let stage: String
  let occurredAt: String
  let durationMs: Double?
  let sequence: Int?
  let metricValue: Double?
  let metricUnit: String?
  let payload: [String: Any]

  init(
    name: String,
    source: String,
    stage: String = "point",
    occurredAt: Date = Date(),
    durationMs: Double? = nil,
    sequence: Int? = nil,
    metricValue: Double? = nil,
    metricUnit: String? = nil,
    payload: [String: Any] = [:]
  ) {
    self.name = name
    self.source = source
    self.stage = stage
    self.occurredAt = Self.formatter.string(from: occurredAt)
    self.durationMs = durationMs
    self.sequence = sequence
    self.metricValue = metricValue
    self.metricUnit = metricUnit
    self.payload = WorkerTelemetryPayloadSanitizer.sanitizedPayload(payload)
  }

  var wirePayload: [String: Any] {
    var payload: [String: Any] = [
      "name": name,
      "source": source,
      "stage": stage,
      "occurredAt": occurredAt
    ]
    if let durationMs { payload["durationMs"] = durationMs }
    if let sequence { payload["sequence"] = sequence }
    if let metricValue { payload["metricValue"] = metricValue }
    if let metricUnit { payload["metricUnit"] = metricUnit }
    if !self.payload.isEmpty { payload["payload"] = self.payload }
    return payload
  }

  private static var formatter: ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }
}

struct WorkerTelemetryBatch: @unchecked Sendable {
  let sessionID: String
  let deviceID: String?
  let workerID: String?
  let platform: String
  let appBuild: String?
  let events: [WorkerTelemetryEvent]

  var payload: [String: Any] {
    var payload: [String: Any] = [
      "sessionId": sessionID,
      "platform": platform,
      "events": events.map(\.wirePayload)
    ]
    if let deviceID { payload["deviceId"] = deviceID }
    if let workerID { payload["workerId"] = workerID }
    if let appBuild { payload["appBuild"] = appBuild }
    return payload
  }
}

enum WorkerTelemetryPayloadSanitizer {
  private static let maxStringLength = 512
  private static let maxArrayLength = 25
  private static let maxObjectKeys = 60
  private static let maxPayloadBytes = 8 * 1024
  private static let maxDepth = 4

  static func sanitizedPayload(_ payload: [String: Any]) -> [String: Any] {
    let sanitized = sanitizeDictionary(payload, depth: 0)
    guard jsonByteCount(sanitized) > maxPayloadBytes else { return sanitized }

    var trimmed: [String: Any] = ["_truncated": true]
    for (key, value) in sanitized {
      trimmed[key] = value
      if jsonByteCount(trimmed) > maxPayloadBytes {
        trimmed.removeValue(forKey: key)
        break
      }
    }
    return trimmed
  }

  private static func sanitizeDictionary(_ payload: [String: Any], depth: Int) -> [String: Any] {
    guard depth <= maxDepth else { return ["_truncated": true] }
    var sanitized: [String: Any] = [:]
    let entries = Array(payload.prefix(maxObjectKeys))
    for (key, value) in entries {
      sanitized[key] = sanitizeValue(value, key: key, depth: depth + 1)
    }
    if payload.count > entries.count {
      sanitized["_truncated"] = true
    }
    return sanitized
  }

  private static func sanitizeValue(_ value: Any, key: String, depth: Int) -> Any {
    if value is NSNull {
      return NSNull()
    }
    if let number = value as? NSNumber {
      return number
    }
    if let string = value as? String {
      return sanitizeString(string, key: key)
    }
    if let array = value as? [Any] {
      var sanitized = array.prefix(maxArrayLength).enumerated().map { index, item in
        sanitizeValue(item, key: "\(key).\(index)", depth: depth + 1)
      }
      if array.count > sanitized.count {
        sanitized.append("[truncated]")
      }
      return sanitized
    }
    if let dictionary = value as? [String: Any] {
      return sanitizeDictionary(dictionary, depth: depth + 1)
    }
    return String(describing: value).prefixString(maxStringLength)
  }

  private static func sanitizeString(_ value: String, key: String) -> String {
    let lowercasedKey = key.lowercased()
    if lowercasedKey.contains("authorization")
      || lowercasedKey.contains("bearer")
      || lowercasedKey.contains("token")
      || lowercasedKey.contains("secret")
      || lowercasedKey.contains("apikey")
      || lowercasedKey.contains("api_key")
      || lowercasedKey.contains("password") {
      return "[redacted]"
    }
    if lowercasedKey.contains("signedurl")
      || lowercasedKey.contains("signed_url")
      || lowercasedKey.contains("uploadurl")
      || lowercasedKey.contains("upload_url") {
      return "[redacted-url]"
    }
    if isRawPayloadKey(lowercasedKey) || looksLikeRawPayload(value) {
      return "[redacted-raw-payload]"
    }
    return value.prefixString(maxStringLength)
  }

  private static func isRawPayloadKey(_ key: String) -> Bool {
    key.contains("base64")
      || key.contains("image_data")
      || key.contains("imagedata")
      || key.contains("audio_data")
      || key.contains("audiodata")
      || key.contains("video_data")
      || key.contains("videodata")
      || key.contains("jpeg_data")
      || key.contains("jpegdata")
      || key.contains("raw_transcript")
      || key == "transcript"
  }

  private static func looksLikeRawPayload(_ value: String) -> Bool {
    if value.hasPrefix("data:image/") || value.hasPrefix("data:audio/") {
      return true
    }
    guard value.count >= 512, value.count % 4 == 0 else { return false }
    return value.range(of: #"^[A-Za-z0-9+/]+={0,2}$"#, options: .regularExpression) != nil
  }

  private static func jsonByteCount(_ payload: [String: Any]) -> Int {
    guard JSONSerialization.isValidJSONObject(payload),
          let data = try? JSONSerialization.data(withJSONObject: payload)
    else {
      return Int.max
    }
    return data.count
  }
}

actor WorkerTelemetry {
  static let shared = WorkerTelemetry()

  typealias Sleeper = @Sendable (UInt64) async -> Void

  private weak var api: WorkerAdminAPI?
  private var sessionID: String?
  private var deviceID: String?
  private var workerID: String?
  private var platform: String
  private var appBuild: String?
  private var sequence: Int = 0
  private var queue: [WorkerTelemetryEvent] = []
  private var flushTask: Task<Void, Never>?
  private var isFlushing = false

  private let flushIntervalNanoseconds: UInt64
  private let maxBatchSize: Int
  private let maxQueueSize: Int
  private let sleeper: Sleeper

  init(
    api: WorkerAdminAPI? = nil,
    sessionID: String? = nil,
    deviceID: String? = nil,
    workerID: String? = nil,
    platform: String = "ios",
    appBuild: String? = WorkerTelemetry.defaultAppBuild,
    flushIntervalNanoseconds: UInt64 = 5_000_000_000,
    maxBatchSize: Int = 20,
    maxQueueSize: Int = 500,
    sleeper: @escaping Sleeper = { nanoseconds in
      guard nanoseconds > 0 else { return }
      try? await Task.sleep(nanoseconds: nanoseconds)
    }
  ) {
    self.api = api
    self.sessionID = sessionID
    self.deviceID = deviceID
    self.workerID = workerID
    self.platform = platform
    self.appBuild = appBuild
    self.flushIntervalNanoseconds = flushIntervalNanoseconds
    self.maxBatchSize = max(1, maxBatchSize)
    self.maxQueueSize = max(1, maxQueueSize)
    self.sleeper = sleeper
  }

  func configure(
    api: WorkerAdminAPI,
    sessionID: String,
    deviceID: String? = GeminiConfig.deviceID,
    workerID: String? = nil,
    platform: String = "ios",
    appBuild: String? = WorkerTelemetry.defaultAppBuild
  ) {
    let cleanedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    if self.sessionID != cleanedSessionID {
      queue.removeAll()
      sequence = 0
    }
    self.api = api
    self.sessionID = cleanedSessionID
    self.deviceID = trimmed(deviceID)
    self.workerID = trimmed(workerID)
    self.platform = platform
    self.appBuild = trimmed(appBuild)
  }

  func record(
    _ name: String,
    source: String,
    stage: String = "point",
    sessionID explicitSessionID: String? = nil,
    durationMs: Double? = nil,
    metricValue: Double? = nil,
    metricUnit: String? = nil,
    payload: [String: Any] = [:]
  ) {
    guard let resolvedSessionID = trimmed(explicitSessionID) ?? sessionID,
          !resolvedSessionID.isEmpty
    else {
      return
    }

    if sessionID == nil {
      sessionID = resolvedSessionID
    }

    sequence += 1
    queue.append(
      WorkerTelemetryEvent(
        name: name,
        source: source,
        stage: stage,
        durationMs: durationMs,
        sequence: sequence,
        metricValue: metricValue,
        metricUnit: metricUnit,
        payload: payload
      )
    )
    if queue.count > maxQueueSize {
      queue.removeFirst(queue.count - maxQueueSize)
    }

    if queue.count >= maxBatchSize {
      Task { await self.flush() }
    } else {
      scheduleFlush()
    }
  }

  func flush() async {
    guard !isFlushing else { return }
    guard let api, let sessionID, !queue.isEmpty else { return }

    let count = min(maxBatchSize, queue.count)
    let events = Array(queue.prefix(count))
    queue.removeFirst(count)
    isFlushing = true

    do {
      try await api.sendWorkerTelemetryBatch(
        WorkerTelemetryBatch(
          sessionID: sessionID,
          deviceID: deviceID,
          workerID: workerID,
          platform: platform,
          appBuild: appBuild,
          events: events
        )
      )
    } catch {
      queue = Array((events + queue).suffix(maxQueueSize))
      NSLog("[telemetry] flush failed: %@", error.localizedDescription)
    }

    isFlushing = false
    if !queue.isEmpty {
      scheduleFlush()
    }
  }

  func flushAndStop() async {
    flushTask?.cancel()
    flushTask = nil
    await flush()
  }

  private func scheduleFlush() {
    guard flushIntervalNanoseconds > 0, flushTask == nil else { return }
    flushTask = Task { [flushIntervalNanoseconds, sleeper] in
      await sleeper(flushIntervalNanoseconds)
      await self.flushAfterDelay()
    }
  }

  private func flushAfterDelay() async {
    flushTask = nil
    await flush()
  }

  private func trimmed(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty
    else {
      return nil
    }
    return value
  }

  private static var defaultAppBuild: String? {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String
    let build = info?["CFBundleVersion"] as? String
    return [version, build].compactMap { $0 }.joined(separator: " ")
  }
}

private extension String {
  func prefixString(_ maxLength: Int) -> String {
    guard count > maxLength else { return self }
    let index = self.index(startIndex, offsetBy: maxLength)
    return "\(self[..<index])..."
  }
}

protocol WorkerAdminAPI: AnyObject {
  func sendWorkerLiveHeartbeat(_ heartbeat: WorkerLiveHeartbeatRequest) async throws -> WorkerLiveHeartbeatResponse
  func requestWorkerMediaUploadTarget(
    sessionID: String,
    assetType: String,
    filename: String,
    contentType: String,
    byteSize: Int,
    source: String?
  ) async throws -> WorkerMediaUploadTarget
  func finalizeWorkerMediaUpload(_ finalize: WorkerMediaFinalizeRequest) async throws
  func uploadBinary(
    to target: WorkerMediaUploadTarget,
    data: Data,
    contentType: String
  ) async throws
  func sendWorkerTelemetryBatch(_ batch: WorkerTelemetryBatch) async throws
  func requestGeminiLiveToken(
    model: String?,
    sessionID: String?
  ) async throws -> GeminiLiveTokenResponse
  func requestGeminiSpotter(_ request: GeminiSpotterRequest) async throws -> GeminiSpotterResponse
}

struct WorkerLiveHeartbeatRequest: Equatable {
  let sessionID: String
  let webrtcRoomCode: String?
  let currentStepIndex: Int
  let helpRequested: Bool
  let status: String
  let lastFrameBucket: String?
  let lastFramePath: String?

  var payload: [String: Any] {
    var payload: [String: Any] = [
      "sessionId": sessionID,
      "currentStepIndex": currentStepIndex,
      "helpRequested": helpRequested,
      "status": status
    ]
    if let webrtcRoomCode {
      payload["webrtcRoomCode"] = webrtcRoomCode
    }
    if let lastFrameBucket {
      payload["lastFrameBucket"] = lastFrameBucket
    }
    if let lastFramePath {
      payload["lastFramePath"] = lastFramePath
    }
    return payload
  }
}

struct WorkerLiveHeartbeatResponse: Decodable, Equatable {
  let sessionID: String
  let updatedAt: String?
  let isFreshLiveSession: Bool
  let webrtcRoomCode: String?
  let supportMode: String
  let aiSessionStatus: String
  let humanSupportStatus: String
  let supportUpdatedAt: String?
  let shouldOpenLiveRoom: Bool

  private enum CodingKeys: String, CodingKey {
    case sessionID = "sessionId"
    case updatedAt
    case isFreshLiveSession
    case webrtcRoomCode
    case supportMode
    case aiSessionStatus
    case humanSupportStatus
    case supportUpdatedAt
    case shouldOpenLiveRoom
  }

  init(
    sessionID: String,
    updatedAt: String? = nil,
    isFreshLiveSession: Bool = false,
    webrtcRoomCode: String? = nil,
    supportMode: String = "ai",
    aiSessionStatus: String = "active",
    humanSupportStatus: String = "none",
    supportUpdatedAt: String? = nil,
    shouldOpenLiveRoom: Bool = false
  ) {
    self.sessionID = sessionID
    self.updatedAt = updatedAt
    self.isFreshLiveSession = isFreshLiveSession
    self.webrtcRoomCode = webrtcRoomCode
    self.supportMode = supportMode
    self.aiSessionStatus = aiSessionStatus
    self.humanSupportStatus = humanSupportStatus
    self.supportUpdatedAt = supportUpdatedAt
    self.shouldOpenLiveRoom = shouldOpenLiveRoom
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessionID = try container.decode(String.self, forKey: .sessionID)
    updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    isFreshLiveSession = try container.decodeIfPresent(Bool.self, forKey: .isFreshLiveSession) ?? false
    webrtcRoomCode = try container.decodeIfPresent(String.self, forKey: .webrtcRoomCode)
    supportMode = try container.decodeIfPresent(String.self, forKey: .supportMode) ?? "ai"
    aiSessionStatus = try container.decodeIfPresent(String.self, forKey: .aiSessionStatus) ?? "active"
    humanSupportStatus = try container.decodeIfPresent(String.self, forKey: .humanSupportStatus) ?? "none"
    supportUpdatedAt = try container.decodeIfPresent(String.self, forKey: .supportUpdatedAt)
    shouldOpenLiveRoom = try container.decodeIfPresent(Bool.self, forKey: .shouldOpenLiveRoom) ?? false
  }
}

struct WorkerMediaUploadTarget: Decodable, Equatable, Sendable {
  let assetID: String
  let bucket: String
  let path: String
  let uploadURL: String
  let method: String
  let headers: [String: String]

  init(
    assetID: String,
    bucket: String,
    path: String,
    uploadURL: String,
    method: String = "PUT",
    headers: [String: String] = [:]
  ) {
    self.assetID = assetID
    self.bucket = bucket
    self.path = path
    self.uploadURL = uploadURL
    self.method = method
    self.headers = headers
  }

  private enum CodingKeys: String, CodingKey {
    case assetID = "asset_id"
    case assetIDCamel = "assetId"
    case bucket
    case path
    case uploadURL = "upload_url"
    case uploadURLCamel = "uploadUrl"
    case method
    case headers
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard let assetID = try container.decodeFirstString(forKeys: [.assetID, .assetIDCamel]),
          let bucket = try container.decodeFirstString(forKeys: [.bucket]),
          let path = try container.decodeFirstString(forKeys: [.path]),
          let uploadURL = try container.decodeFirstString(forKeys: [.uploadURL, .uploadURLCamel])
    else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Missing worker media upload target fields")
      )
    }
    self.assetID = assetID
    self.bucket = bucket
    self.path = path
    self.uploadURL = uploadURL
    self.method = try container.decodeIfPresent(String.self, forKey: .method) ?? "PUT"
    self.headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
  }
}

struct WorkerMediaFinalizeRequest: Equatable {
  let assetID: String
  let sessionID: String
  let bucket: String
  let path: String
  let status: String
  let byteSize: Int
  let error: String?

  var payload: [String: Any] {
    var payload: [String: Any] = [
      "assetId": assetID,
      "sessionId": sessionID,
      "bucket": bucket,
      "path": path,
      "status": status,
      "byteSize": byteSize
    ]
    if let error {
      payload["error"] = error
    }
    return payload
  }
}

struct GeminiLiveTokenResponse: Decodable, Equatable {
  let token: String
  let expiresAt: String
  let newSessionExpiresAt: String
  let model: String
  let websocketBaseURL: String
  let queryParameterName: String
  let systemInstruction: String?
  let runtimeContext: GeminiRuntimeContextEnvelope?
  let diagnosticsID: String?
  let provider: String?

  private enum CodingKeys: String, CodingKey {
    case token
    case expiresAt
    case newSessionExpiresAt
    case model
    case websocketBaseURL
    case queryParameterName
    case systemInstruction
    case runtimeContext
    case diagnosticsID = "diagnosticsId"
    case provider
  }

  var credential: GeminiLiveCredential {
    GeminiLiveCredential(
      token: token,
      queryParameterName: queryParameterName.isEmpty ? "access_token" : queryParameterName,
      websocketBaseURL: websocketBaseURL.isEmpty ? GeminiConfig.ephemeralTokenWebsocketBaseURL : websocketBaseURL,
      model: model.isEmpty ? GeminiConfig.model : model
    )
  }
}

struct GeminiRuntimeContextEnvelope: Decodable, Equatable {
  let rawSummary: String

  init(from decoder: Decoder) throws {
    if let container = try? decoder.singleValueContainer(),
       container.decodeNil() {
      rawSummary = ""
      return
    }
    rawSummary = "runtime-context"
  }
}

struct GeminiSpotterRequest: Equatable {
  let sessionID: String
  let stepID: String
  let stepTitle: String
  let aiPrompt: String
  let expectedObjects: [String]
  let preconditions: [String]
  let postconditions: [String]
  let skipRisk: String
  let evidenceRequired: Bool
  let imageBase64: String
  let imageMimeType: String
  let capturedAt: String
  let critical: Bool
  let allowAIComplete: Bool
  let elapsedActiveMs: Int?

  var payload: [String: Any] {
    var payload: [String: Any] = [
      "sessionId": sessionID,
      "stepId": stepID,
      "stepTitle": stepTitle,
      "aiPrompt": aiPrompt,
      "expectedObjects": expectedObjects,
      "preconditions": preconditions,
      "postconditions": postconditions,
      "skipRisk": skipRisk,
      "evidenceRequired": evidenceRequired,
      "imageBase64": imageBase64,
      "imageMimeType": imageMimeType,
      "capturedAt": capturedAt,
      "critical": critical,
      "allowAIComplete": allowAIComplete
    ]
    if let elapsedActiveMs {
      payload["elapsedActiveMs"] = elapsedActiveMs
    }
    return payload
  }
}

struct GeminiSpotterResponse: Decodable, Equatable {
  let matched: Bool
  let confidence: Double
  let reason: String
  let evidenceTimestamp: String
  let threshold: Double?
  let model: String?
  let autoComplete: Bool
  let modelAutoComplete: Bool?
  let evidenceWindowSatisfied: Bool?
  let activeDurationSatisfied: Bool?
  let elapsedActiveMs: Int?
  let minActiveSeconds: Double?
  let stableObservations: Int?
  let stableObservationsRequired: Int?
  let advancedToStepIndex: Int?
  let completedSop: Bool?
  let packageProgressWarning: String?

  private enum CodingKeys: String, CodingKey {
    case matched
    case confidence
    case reason
    case evidenceTimestamp
    case threshold
    case model
    case autoComplete
    case modelAutoComplete
    case evidenceWindowSatisfied
    case activeDurationSatisfied
    case elapsedActiveMs
    case minActiveSeconds
    case stableObservations
    case stableObservationsRequired
    case advancedToStepIndex
    case completedSop
    case packageProgressWarning
  }
}

struct BackendMemoryLink: Identifiable, Decodable, Equatable {
  let id: String
}

struct BackendPackageExecutionRun: Identifiable, Decodable, Equatable {
  let id: String
  let packageID: String?
  let status: String?
  let completedAt: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case packageID = "package_id"
    case status
    case completedAt = "completed_at"
  }
}

private struct HealthResponse: Decodable {
  let status: String
  let service: String
}

struct ExecutionSessionPatch {
  var status: String?
  var currentSopID: String?
  var currentStepIndex: Int?
  var helpRequested: Bool?
  var webrtcRoomCode: String?
  var lastFrameBucket: String?
  var lastFramePath: String?
  var endedAt: String?

  var payload: [String: Any] {
    var payload: [String: Any] = [:]
    if let status { payload["status"] = status }
    if let currentSopID { payload["current_sop_id"] = currentSopID }
    if let currentStepIndex { payload["current_step_index"] = currentStepIndex }
    if let helpRequested { payload["help_requested"] = helpRequested }
    if let webrtcRoomCode = webrtcRoomCode?.trimmingCharacters(in: .whitespacesAndNewlines),
       !webrtcRoomCode.isEmpty {
      payload["webrtc_room_code"] = webrtcRoomCode
    }
    if let lastFrameBucket = lastFrameBucket?.trimmingCharacters(in: .whitespacesAndNewlines),
       !lastFrameBucket.isEmpty {
      payload["last_frame_bucket"] = lastFrameBucket
    }
    if let lastFramePath = lastFramePath?.trimmingCharacters(in: .whitespacesAndNewlines),
       !lastFramePath.isEmpty {
      payload["last_frame_path"] = lastFramePath
    }
    if let endedAt { payload["ended_at"] = endedAt }
    return payload
  }
}

enum OpsAPIError: LocalizedError {
  case notConfigured
  case invalidURL(String)
  case invalidResponse
  case missingWorkerSession
  case missingWorkerBearerToken
  case server(statusCode: Int, message: String)

  var errorDescription: String? {
    switch self {
    case .notConfigured:
      return "Ops API base URL is not configured."
    case .invalidURL(let path):
      return "Invalid URL for path \(path)."
    case .invalidResponse:
      return "The ops-api returned an invalid response."
    case .missingWorkerSession:
      return "Worker session is missing. Re-bootstrap before writing execution state."
    case .missingWorkerBearerToken:
      return "Worker bearer token is missing. Re-bootstrap or configure a worker bearer token in Settings."
    case .server(let statusCode, let message):
      return "ops-api returned HTTP \(statusCode): \(message)"
    }
  }
}

enum AdminIngestError: LocalizedError {
  case notConfigured
  case invalidURL(String)
  case invalidResponse
  case missingWorkerBearerToken
  case server(statusCode: Int, url: String, message: String)

  var errorDescription: String? {
    switch self {
    case .notConfigured:
      return "Admin ingest base URL is not configured."
    case .invalidURL(let path):
      return "Invalid admin ingest URL for path \(path)."
    case .invalidResponse:
      return "The admin ingest service returned an invalid response."
    case .missingWorkerBearerToken:
      return "Worker bearer token is missing. Re-bootstrap or configure a worker bearer token in Settings."
    case .server(let statusCode, let url, let message):
      return "Admin ingest returned HTTP \(statusCode) from \(url): \(message)"
    }
  }
}

final class OpsAPIClient: WorkerAdminAPI {
  private let session: URLSession
  private let decoder: JSONDecoder
  private var workerSessionToken: String?

  init(session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 15
    return URLSession(configuration: config)
  }()) {
    self.session = session
    self.decoder = JSONDecoder()
  }

  var isConfigured: Bool {
    GeminiConfig.isOpsConfigured
  }

  var currentWorkerBearerToken: String? {
    let liveToken = workerSessionToken?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let liveToken, !liveToken.isEmpty {
      return liveToken
    }

    let configuredToken = GeminiConfig.workerAPIBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
    return configuredToken.isEmpty ? nil : configuredToken
  }

  func health() async throws -> String {
    let response: HealthResponse = try await performRequest(path: "/health", method: "GET")
    return "\(response.status):\(response.service)"
  }

  func bootstrap(
    loginCode: String?,
    email: String?,
    platform: String,
    label: String
  ) async throws -> BootstrapPayload {
    var payload: [String: Any] = [
      "platform": platform,
      "label": label,
      "device_label": label
    ]
    if let loginCode, !loginCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      payload["login_code"] = loginCode
    }
    if let email, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      payload["email"] = email
    }
    let response: BootstrapPayload = try await performRequest(
      path: "/v1/bootstrap",
      method: "POST",
      requiresWorkerAuth: false,
      payload: payload
    )
    workerSessionToken = response.workerSessionToken?.trimmingCharacters(in: .whitespacesAndNewlines)
    return response
  }

  func createExecutionSession(
    workerID: String,
    deviceID: String?,
    shiftID: String?,
    packageID: String?,
    packageRunID: String?,
    currentSopID: String?,
    sopVersion: Int?,
    packageVersion: Int?,
    status: String = "active"
  ) async throws -> BackendExecutionSession {
    var payload: [String: Any] = [
      "worker_id": workerID,
      "status": status
    ]
    if let deviceID { payload["device_id"] = deviceID }
    if let shiftID { payload["shift_id"] = shiftID }
    if let packageID { payload["package_id"] = packageID }
    if let packageRunID { payload["package_run_id"] = packageRunID }
    if let currentSopID { payload["current_sop_id"] = currentSopID }
    if let sopVersion { payload["sop_version"] = sopVersion }
    if let packageVersion { payload["package_version"] = packageVersion }
    return try await performRequest(
      path: "/v1/execution-sessions",
      method: "POST",
      requiresWorkerAuth: true,
      payload: payload
    )
  }

  func updateExecutionSession(
    id: String,
    patch: ExecutionSessionPatch
  ) async throws -> BackendExecutionSession {
    try await performRequest(
      path: "/v1/execution-sessions/\(id)",
      method: "PATCH",
      requiresWorkerAuth: true,
      payload: patch.payload
    )
  }

  func postExecutionEvent(
    sessionID: String,
    eventType: String,
    payload: [String: Any]
  ) async throws -> BackendExecutionEvent {
    try await performRequest(
      path: "/v1/execution-sessions/\(sessionID)/events",
      method: "POST",
      requiresWorkerAuth: true,
      payload: [
        "event_type": eventType,
        "payload": payload
      ]
    )
  }

  func createIntervention(
    sessionID: String,
    type: String,
    notes: String?
  ) async throws -> BackendIntervention {
    var payload: [String: Any] = [
      "session_id": sessionID,
      "type": type
    ]
    if let notes, !notes.isEmpty {
      payload["notes"] = notes
    }
    return try await performRequest(
      path: "/v1/interventions",
      method: "POST",
      requiresWorkerAuth: true,
      payload: payload
    )
  }

  func registerMediaAsset(
    sessionID: String,
    bucket: String,
    path: String,
    assetType: String,
    metadata: [String: Any]
  ) async throws -> BackendMediaAsset {
    try await performRequest(
      path: "/v1/media-assets",
      method: "POST",
      requiresWorkerAuth: true,
      payload: [
        "session_id": sessionID,
        "bucket": bucket,
        "path": path,
        "asset_type": assetType,
        "metadata": metadata
      ]
    )
  }

  func createMemoryLink(
    sourceID: String,
    sourceType: String,
    targetID: String,
    targetType: String,
    linkType: String,
    metadata: [String: Any]
  ) async throws -> BackendMemoryLink {
    try await performRequest(
      path: "/v1/memory-links",
      method: "POST",
      requiresWorkerAuth: true,
      payload: [
        "source_id": sourceID,
        "source_type": sourceType,
        "target_id": targetID,
        "target_type": targetType,
        "link_type": linkType,
        "metadata": metadata
      ]
    )
  }

  func requestMediaUploadTarget(
    assetID: String,
    contentType: String,
    byteCount: Int
  ) async throws -> BackendMediaUploadTarget {
    try await performRequest(
      path: "/v1/media-assets/\(assetID)/upload-target",
      method: "POST",
      requiresWorkerAuth: true,
      payload: [
        "content_type": contentType,
        "byte_count": byteCount
      ]
    )
  }

  func finalizeMediaAssetUpload(
    assetID: String,
    uploadState: String = "uploaded",
    byteCount: Int,
    contentType: String
  ) async throws -> BackendMediaAsset {
    try await performRequest(
      path: "/v1/media-assets/\(assetID)/finalize",
      method: "POST",
      requiresWorkerAuth: true,
      payload: [
        "upload_state": uploadState,
        "byte_count": byteCount,
        "content_type": contentType
      ]
    )
  }

  func uploadBinary(
    to target: BackendMediaUploadTarget,
    data: Data,
    contentType: String
  ) async throws {
    guard let url = URL(string: target.uploadURL), !target.uploadURL.isEmpty else {
      throw OpsAPIError.invalidURL(target.uploadURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = target.method.isEmpty ? "PUT" : target.method
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    for (name, value) in target.headers {
      request.setValue(value, forHTTPHeaderField: name)
    }

    let (_, response) = try await session.upload(for: request, from: data)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw OpsAPIError.invalidResponse
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      throw OpsAPIError.server(statusCode: httpResponse.statusCode, message: "Media upload failed")
    }
  }

  func sendWorkerLiveHeartbeat(_ heartbeat: WorkerLiveHeartbeatRequest) async throws -> WorkerLiveHeartbeatResponse {
    let data = try await performWorkerRequest(
      path: "/api/worker/live/heartbeat",
      method: "POST",
      payload: heartbeat.payload
    )

    do {
      return try decoder.decode(WorkerLiveHeartbeatResponse.self, from: data)
    } catch {
      let body = String(data: data, encoding: .utf8) ?? "<non-utf8 response>"
      NSLog("[admin-ingest] Failed decoding /api/worker/live/heartbeat -> %@", body)
      throw error
    }
  }

  func requestWorkerMediaUploadTarget(
    sessionID: String,
    assetType: String,
    filename: String,
    contentType: String,
    byteSize: Int,
    source: String? = nil
  ) async throws -> WorkerMediaUploadTarget {
    var payload: [String: Any] = [
      "sessionId": sessionID,
      "assetType": assetType,
      "filename": filename,
      "contentType": contentType,
      "byteSize": byteSize
    ]
    if let source, !source.isEmpty {
      payload["source"] = source
    }
    let data = try await performWorkerRequest(
      path: "/api/worker/media/upload-target",
      method: "POST",
      payload: payload
    )

    do {
      return try decoder.decode(WorkerMediaUploadTarget.self, from: data)
    } catch {
      let body = String(data: data, encoding: .utf8) ?? "<non-utf8 response>"
      NSLog("[admin-ingest] Failed decoding /api/worker/media/upload-target -> %@", body)
      throw error
    }
  }

  func finalizeWorkerMediaUpload(_ finalize: WorkerMediaFinalizeRequest) async throws {
    _ = try await performWorkerRequest(
      path: "/api/worker/media/finalize",
      method: "POST",
      payload: finalize.payload
    )
  }

  func sendWorkerTelemetryBatch(_ batch: WorkerTelemetryBatch) async throws {
    _ = try await performWorkerRequest(
      path: "/api/worker/telemetry",
      method: "POST",
      payload: batch.payload
    )
  }

  func requestGeminiLiveToken(
    model: String? = nil,
    sessionID: String? = nil
  ) async throws -> GeminiLiveTokenResponse {
    var payload: [String: Any] = [
      "responseModalities": ["AUDIO"]
    ]
    if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
       !model.isEmpty {
      payload["model"] = model
    }
    if let sessionID, !sessionID.isEmpty {
      payload["sessionId"] = sessionID
    }

    let data = try await performWorkerRequest(
      path: "/api/worker/gemini/live-token",
      method: "POST",
      payload: payload
    )

    do {
      return try decoder.decode(GeminiLiveTokenResponse.self, from: data)
    } catch {
      let body = String(data: data, encoding: .utf8) ?? "<non-utf8 response>"
      NSLog("[admin-ingest] Failed decoding /api/worker/gemini/live-token -> %@", body)
      throw error
    }
  }

  func requestGeminiSpotter(_ request: GeminiSpotterRequest) async throws -> GeminiSpotterResponse {
    let data = try await performWorkerRequest(
      path: "/api/worker/gemini/spotter",
      method: "POST",
      payload: request.payload
    )

    do {
      return try decoder.decode(GeminiSpotterResponse.self, from: data)
    } catch {
      let body = String(data: data, encoding: .utf8) ?? "<non-utf8 response>"
      NSLog("[admin-ingest] Failed decoding /api/worker/gemini/spotter -> %@", body)
      throw error
    }
  }

  func uploadBinary(
    to target: WorkerMediaUploadTarget,
    data: Data,
    contentType: String
  ) async throws {
    guard let url = URL(string: target.uploadURL), !target.uploadURL.isEmpty else {
      throw OpsAPIError.invalidURL(target.uploadURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = target.method.isEmpty ? "PUT" : target.method
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    for (name, value) in target.headers {
      request.setValue(value, forHTTPHeaderField: name)
    }

    let (_, response) = try await session.upload(for: request, from: data)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw OpsAPIError.invalidResponse
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      throw OpsAPIError.server(statusCode: httpResponse.statusCode, message: "Media upload failed")
    }
  }

  func closePackageRun(
    packageRunID: String,
    workerID: String
  ) async throws -> BackendPackageExecutionRun {
    try await performRequest(
      path: "/v1/package-runs/\(packageRunID)/close",
      method: "POST",
      requiresWorkerAuth: true,
      payload: [
        "worker_id": workerID
      ]
    )
  }

  private func performRequest<Response: Decodable>(
    path: String,
    method: String,
    requiresWorkerAuth: Bool = false,
    payload: [String: Any]? = nil
  ) async throws -> Response {
    guard isConfigured else {
      throw OpsAPIError.notConfigured
    }

    guard let url = makeURL(path: path, baseURLString: GeminiConfig.opsBaseURL) else {
      throw OpsAPIError.invalidURL(path)
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    if requiresWorkerAuth {
      guard let token = workerSessionToken?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
      else {
        throw OpsAPIError.missingWorkerSession
      }
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    if let payload {
      request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw OpsAPIError.invalidResponse
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      let message = String(data: data, encoding: .utf8) ?? "Unknown error"
      throw OpsAPIError.server(statusCode: httpResponse.statusCode, message: message)
    }

    do {
      return try decoder.decode(Response.self, from: data)
    } catch {
      let body = String(data: data, encoding: .utf8) ?? "<non-utf8 response>"
      NSLog("[ops-api] Failed decoding %@ -> %@", path, body)
      throw error
    }
  }

  private func makeURL(path: String, baseURLString: String) -> URL? {
    let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let normalizedBase: String
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
      normalizedBase = trimmed
    } else {
      normalizedBase = "https://\(trimmed)"
    }

    guard var components = URLComponents(string: normalizedBase) else {
      return nil
    }
    let cleanedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    components.path = "/" + [cleanedPath, path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
      .filter { !$0.isEmpty }
      .joined(separator: "/")
    return components.url
  }

  private func performWorkerRequest(
    path: String,
    method: String,
    payload: [String: Any]? = nil
  ) async throws -> Data {
    guard GeminiConfig.isAdminConfigured else {
      throw AdminIngestError.notConfigured
    }

    guard let url = makeURL(path: path, baseURLString: GeminiConfig.adminBaseURL) else {
      throw AdminIngestError.invalidURL(path)
    }

    guard let token = currentWorkerBearerToken else {
      throw AdminIngestError.missingWorkerBearerToken
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    if let payload {
      request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw AdminIngestError.invalidResponse
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      let message = summarizeResponseBody(data)
      NSLog(
        "[admin-ingest] %@ %@ -> %d %@",
        method,
        url.absoluteString,
        httpResponse.statusCode,
        message
      )
      throw AdminIngestError.server(
        statusCode: httpResponse.statusCode,
        url: url.absoluteString,
        message: message
      )
    }

    return data
  }

  private func summarizeResponseBody(_ data: Data) -> String {
    let raw = String(data: data, encoding: .utf8) ?? "Unknown error"
    let compact = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard compact.count > 240 else { return compact }
    let endIndex = compact.index(compact.startIndex, offsetBy: 240)
    return "\(compact[..<endIndex])..."
  }
}
