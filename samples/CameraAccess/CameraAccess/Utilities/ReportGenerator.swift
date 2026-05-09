import UIKit

@MainActor
class ReportGenerator {
  private let context: SessionContext
  private let pageWidth: CGFloat = 612
  private let pageHeight: CGFloat = 792
  private let margin: CGFloat = 50

  init(context: SessionContext) {
    self.context = context
  }

  func generatePDF(title: String = "Field Report") async -> Result<URL, Error> {
    let contentWidth = pageWidth - margin * 2
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short

    let timeFormatter = DateFormatter()
    timeFormatter.timeStyle = .short

    let data = renderer.pdfData { pdfContext in
      var yOffset: CGFloat = 0

      func newPage() {
        pdfContext.beginPage()
        yOffset = margin
      }

      func checkPageBreak(_ needed: CGFloat) {
        if yOffset + needed > pageHeight - margin { newPage() }
      }

      newPage()

      // Title bar
      let titleBarRect = CGRect(x: margin, y: yOffset, width: contentWidth, height: 50)
      UIColor(red: 0.05, green: 0.1, blue: 0.25, alpha: 1.0).setFill()
      UIBezierPath(roundedRect: titleBarRect, cornerRadius: 8).fill()

      let titleAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 24, weight: .bold), .foregroundColor: UIColor.white]
      (title as NSString).draw(at: CGPoint(x: margin + 16, y: yOffset + 12), withAttributes: titleAttrs)

      let badgeAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: UIColor.white.withAlphaComponent(0.7)]
      let badge = "VisionClaw AI Field Assistant" as NSString
      let badgeSize = badge.size(withAttributes: badgeAttrs)
      badge.draw(at: CGPoint(x: margin + contentWidth - badgeSize.width - 16, y: yOffset + 20), withAttributes: badgeAttrs)

      yOffset += 70

      let labelAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: UIColor.black]
      let bodyAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12, weight: .regular), .foregroundColor: UIColor.darkGray]
      let sectionHeader: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1.0)]

      ("JOB DETAILS" as NSString).draw(at: CGPoint(x: margin, y: yOffset), withAttributes: sectionHeader)
      yOffset += 24

      let detailX = margin + 12

      func drawField(label: String, value: String) {
        checkPageBreak(20)
        (label as NSString).draw(at: CGPoint(x: detailX, y: yOffset), withAttributes: labelAttrs)
        let labelWidth = (label as NSString).size(withAttributes: labelAttrs).width
        (value as NSString).draw(at: CGPoint(x: detailX + labelWidth + 4, y: yOffset), withAttributes: bodyAttrs)
        yOffset += 18
      }

      if !context.workerName.isEmpty { drawField(label: "Worker:", value: context.workerName) }
      if !context.jobId.isEmpty { drawField(label: "Job ID:", value: context.jobId) }
      if !context.jobDescription.isEmpty { drawField(label: "Description:", value: context.jobDescription) }
      if !context.siteAddress.isEmpty { drawField(label: "Site:", value: context.siteAddress) }
      if let coords = context.coordinates {
        let locStr = String(format: "%.5f, %.5f", coords.lat, coords.lon) + (context.reverseGeocodedAddress.map { " (\($0))" } ?? "")
        drawField(label: "GPS:", value: locStr)
      }
      let duration = Date().timeIntervalSince(context.sessionStartTime)
      drawField(label: "Session:", value: "\(formatter.string(from: context.sessionStartTime)) (\(Int(duration) / 60) min)")
      drawField(label: "Photos saved:", value: "\(context.photosSaved)")
      drawField(label: "Notes recorded:", value: "\(context.notes.count)")
      yOffset += 20

      // Photos section
      if !context.savedPhotos.isEmpty {
        checkPageBreak(40)
        ("CAPTURED PHOTOS" as NSString).draw(at: CGPoint(x: margin, y: yOffset), withAttributes: sectionHeader)
        yOffset += 24

        let photoWidth: CGFloat = (contentWidth - 12) / 2
        let photoHeight: CGFloat = photoWidth * 0.75

        for (index, photo) in context.savedPhotos.enumerated() {
          let isLeftColumn = index % 2 == 0
          if isLeftColumn { checkPageBreak(photoHeight + 30) }

          let xPos = isLeftColumn ? margin : margin + photoWidth + 12
          let imageRect = CGRect(x: xPos, y: yOffset, width: photoWidth, height: photoHeight)
          photo.image.draw(in: imageRect)

          // Border
          UIColor.lightGray.setStroke()
          UIBezierPath(rect: imageRect).stroke()

          // Caption
          let captionAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9, weight: .regular), .foregroundColor: UIColor.darkGray]
          let timeStr = timeFormatter.string(from: photo.timestamp)
          let caption = "\(timeStr) — \(photo.description)" as NSString
          caption.draw(in: CGRect(x: xPos, y: yOffset + photoHeight + 2, width: photoWidth, height: 14), withAttributes: captionAttrs)

          if !isLeftColumn || index == context.savedPhotos.count - 1 {
            yOffset += photoHeight + 22
          }
        }
        yOffset += 10
      }

      let categoryOrder = ["hazard", "action_item", "observation", "measurement", "reference", "general"]
      let categoryLabels: [String: String] = ["hazard": "HAZARDS & SAFETY ISSUES", "action_item": "ACTION ITEMS", "observation": "OBSERVATIONS", "measurement": "MEASUREMENTS", "reference": "REFERENCES & LOOKUPS", "general": "GENERAL NOTES"]
      let categoryColors: [String: UIColor] = ["hazard": UIColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1.0), "action_item": UIColor(red: 0.8, green: 0.5, blue: 0.0, alpha: 1.0), "observation": UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1.0), "measurement": UIColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1.0), "reference": UIColor(red: 0.5, green: 0.2, blue: 0.7, alpha: 1.0), "general": UIColor.gray]

      let noteFont = UIFont.systemFont(ofSize: 11, weight: .regular)
      let noteTimeFont = UIFont.systemFont(ofSize: 10, weight: .medium)

      for category in categoryOrder {
        let categoryNotes = context.notes.filter { $0.category == category }
        guard !categoryNotes.isEmpty else { continue }
        checkPageBreak(60)
        let catColor = categoryColors[category] ?? .gray
        let catLabel = categoryLabels[category] ?? category.uppercased()
        catColor.setFill()
        UIBezierPath(rect: CGRect(x: margin, y: yOffset, width: 4, height: 18)).fill()
        let catAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: catColor]
        (catLabel as NSString).draw(at: CGPoint(x: margin + 10, y: yOffset), withAttributes: catAttrs)
        yOffset += 26

        for note in categoryNotes {
          let timeStr = timeFormatter.string(from: note.timestamp)
          let noteSize = (note.text as NSString).boundingRect(with: CGSize(width: contentWidth - 20, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin, attributes: [.font: noteFont], context: nil)
          checkPageBreak(noteSize.height + 12)
          ("\u{2022}" as NSString).draw(at: CGPoint(x: margin + 4, y: yOffset), withAttributes: [.font: noteFont, .foregroundColor: catColor])
          let timeAttrs: [NSAttributedString.Key: Any] = [.font: noteTimeFont, .foregroundColor: UIColor.gray]
          (timeStr as NSString).draw(at: CGPoint(x: margin + 16, y: yOffset), withAttributes: timeAttrs)
          let textX = margin + 16 + (timeStr as NSString).size(withAttributes: timeAttrs).width + 8
          (note.text as NSString).draw(in: CGRect(x: textX, y: yOffset, width: contentWidth - (textX - margin), height: noteSize.height + 4), withAttributes: [.font: noteFont, .foregroundColor: UIColor.darkGray])
          yOffset += max(noteSize.height + 4, 16)

          // Append pose line (e.g. "Multiset VPS ±5 cm | map:office-1 (2.31, 1.05, 0.82)")
          if let pose = note.pose {
            let poseAttrs: [NSAttributedString.Key: Any] = [
              .font: UIFont.systemFont(ofSize: 8, weight: .regular),
              .foregroundColor: UIColor.lightGray
            ]
            ("📍 " + pose.summary as NSString).draw(at: CGPoint(x: margin + 24, y: yOffset), withAttributes: poseAttrs)
            yOffset += 12
          }
        }
        yOffset += 12
      }

      checkPageBreak(40)
      yOffset += 10
      UIColor.lightGray.setFill()
      UIBezierPath(rect: CGRect(x: margin, y: yOffset, width: contentWidth, height: 0.5)).fill()
      yOffset += 8
      ("Generated by VisionClaw AI Field Assistant on \(formatter.string(from: Date()))" as NSString).draw(at: CGPoint(x: margin, y: yOffset), withAttributes: [.font: UIFont.systemFont(ofSize: 9, weight: .regular), .foregroundColor: UIColor.lightGray])
    }

    let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none).replacingOccurrences(of: "/", with: "-")
    let jobPart = context.jobId.isEmpty ? "" : "_\(context.jobId)"
    let fileName = "VisionClaw_Report\(jobPart)_\(dateStr).pdf"
    let fileURL = documentsURL.appendingPathComponent(fileName)

    do {
      try data.write(to: fileURL)
      NSLog("[Report] PDF saved: %@", fileURL.lastPathComponent)
      return .success(fileURL)
    } catch {
      NSLog("[Report] Failed to save PDF: %@", error.localizedDescription)
      return .failure(error)
    }
  }
}
