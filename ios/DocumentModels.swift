import Foundation

struct Document: Identifiable, Codable, Hashable, Equatable {
    let id: UUID
    let title: String
    let content: String
    let summary: String
    let ocrPages: [OCRPage]?
    let category: DocumentCategory
    let keywordsResume: String
    let tags: [String]
    let sourceDocumentId: UUID?
    let dateCreated: Date
    let folderId: UUID?
    let sortOrder: Int
    let type: DocumentType
    let imageData: [Data]?
    let pdfData: Data?
    let originalFileData: Data?

    enum DocumentCategory: String, CaseIterable, Codable {
        case general = "General"
        case resume = "Resume"
        case legal = "Legal"
        case finance = "Finance"
        case medical = "Medical"
        case identity = "Identity"
        case notes = "Notes"
        case receipts = "Receipts"
    }

    enum DocumentType: String, CaseIterable, Codable {
        case pdf
        case docx
        case ppt
        case pptx
        case xls
        case xlsx
        case image
        case scanned
        case text
        case zip
    }

    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        summary: String,
        ocrPages: [OCRPage]? = nil,
        category: DocumentCategory = .general,
        keywordsResume: String = "",
        tags: [String] = [],
        sourceDocumentId: UUID? = nil,
        dateCreated: Date = Date(),
        folderId: UUID? = nil,
        sortOrder: Int = 0,
        type: DocumentType,
        imageData: [Data]?,
        pdfData: Data?,
        originalFileData: Data? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.summary = summary
        self.ocrPages = ocrPages
        self.category = category
        self.keywordsResume = keywordsResume
        self.tags = tags
        self.sourceDocumentId = sourceDocumentId
        self.dateCreated = dateCreated
        self.folderId = folderId
        self.sortOrder = sortOrder
        self.type = type
        self.imageData = imageData
        self.pdfData = pdfData
        self.originalFileData = originalFileData
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case content
        case summary
        case ocrPages
        case category
        case keywordsResume
        case tags
        case sourceDocumentId
        case dateCreated
        case folderId
        case sortOrder
        case type
        case imageData
        case pdfData
        case originalFileData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        content = try container.decode(String.self, forKey: .content)
        summary = try container.decode(String.self, forKey: .summary)
        ocrPages = try container.decodeIfPresent([OCRPage].self, forKey: .ocrPages)
        category = try container.decode(DocumentCategory.self, forKey: .category)
        keywordsResume = try container.decodeIfPresent(String.self, forKey: .keywordsResume) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        sourceDocumentId = try container.decodeIfPresent(UUID.self, forKey: .sourceDocumentId)
        dateCreated = try container.decode(Date.self, forKey: .dateCreated)
        folderId = try container.decodeIfPresent(UUID.self, forKey: .folderId)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        type = try container.decode(DocumentType.self, forKey: .type)
        imageData = try container.decodeIfPresent([Data].self, forKey: .imageData)
        pdfData = try container.decodeIfPresent(Data.self, forKey: .pdfData)
        originalFileData = try container.decodeIfPresent(Data.self, forKey: .originalFileData)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(content, forKey: .content)
        try container.encode(summary, forKey: .summary)
        try container.encodeIfPresent(ocrPages, forKey: .ocrPages)
        try container.encode(category, forKey: .category)
        try container.encode(keywordsResume, forKey: .keywordsResume)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(sourceDocumentId, forKey: .sourceDocumentId)
        try container.encode(dateCreated, forKey: .dateCreated)
        try container.encodeIfPresent(folderId, forKey: .folderId)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(imageData, forKey: .imageData)
        try container.encodeIfPresent(pdfData, forKey: .pdfData)
        try container.encodeIfPresent(originalFileData, forKey: .originalFileData)
    }
}

struct OCRBoundingBox: Codable, Hashable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct OCRBlock: Codable, Hashable, Equatable {
    let text: String
    let confidence: Double
    let bbox: OCRBoundingBox
    let order: Int
}

struct OCRPage: Codable, Hashable, Equatable {
    let pageIndex: Int
    let blocks: [OCRBlock]
}

struct DocumentFolder: Identifiable, Codable, Hashable, Equatable {
    let id: UUID
    let name: String
    let dateCreated: Date
    let parentId: UUID?
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case dateCreated
        case parentId
        case sortOrder
    }

    init(name: String, parentId: UUID? = nil, sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.dateCreated = Date()
        self.parentId = parentId
        self.sortOrder = sortOrder
    }

    init(id: UUID, name: String, dateCreated: Date, parentId: UUID? = nil, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.dateCreated = dateCreated
        self.parentId = parentId
        self.sortOrder = sortOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.dateCreated = try container.decode(Date.self, forKey: .dateCreated)
        self.parentId = try container.decodeIfPresent(UUID.self, forKey: .parentId)
        self.sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }
}

func splitDisplayTitle(_ title: String) -> (base: String, ext: String) {
    let u = URL(fileURLWithPath: title)
    let ext = u.pathExtension
    let base = ext.isEmpty ? title : u.deletingPathExtension().lastPathComponent
    return (base: base, ext: ext)
}

func fileExtension(for type: Document.DocumentType) -> String {
    switch type {
    case .pdf: return "pdf"
    case .docx: return "docx"
    case .ppt: return "ppt"
    case .pptx: return "pptx"
    case .xls: return "xls"
    case .xlsx: return "xlsx"
    case .image: return "jpg"
    case .scanned: return "pdf"
    case .text: return "txt"
    case .zip: return "zip"
    }
}

func fileTypeLabel(documentType: Document.DocumentType, titleParts: (base: String, ext: String)) -> String {
    if !titleParts.ext.isEmpty {
        return titleParts.ext.uppercased()
    }
    switch documentType {
    case .scanned: return "PDF"
    case .image: return "JPG"
    case .text: return "TXT"
    case .pdf: return "PDF"
    case .docx: return "DOCX"
    case .ppt: return "PPT"
    case .pptx: return "PPTX"
    case .xls: return "XLS"
    case .xlsx: return "XLSX"
    case .zip: return "ZIP"
    }
}

func iconForDocumentType(_ type: Document.DocumentType) -> String {
    switch type {
    case .pdf:
        return "doc.richtext"
    case .docx:
        return "doc.text"
    case .ppt, .pptx:
        return "play.rectangle.on.rectangle"
    case .xls, .xlsx:
        return "tablecells"
    case .image:
        return "photo"
    case .scanned:
        return "doc.text.viewfinder"
    case .text:
        return "doc.plaintext"
    case .zip:
        return zipSymbolName()
    }
}

func zipSymbolName() -> String {
    return "zipper.page"
}
