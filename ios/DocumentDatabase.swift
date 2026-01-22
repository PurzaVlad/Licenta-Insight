import CoreData
import Foundation

// MARK: - Core Data Document Entity
@objc(DocumentEntity)
public class DocumentEntity: NSManagedObject {
    
}

extension DocumentEntity {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<DocumentEntity> {
        return NSFetchRequest<DocumentEntity>(entityName: "DocumentEntity")
    }

    @NSManaged public var id: UUID
    @NSManaged public var title: String
    @NSManaged public var content: String
    @NSManaged public var ocrText: String
    @NSManaged public var summary: String
    @NSManaged public var category: String
    @NSManaged public var keywordsResume: String
    @NSManaged public var dateCreated: Date
    @NSManaged public var documentType: String
    @NSManaged public var fileData: Data?
    @NSManaged public var thumbnailData: Data?
}

// MARK: - Document Database Manager
class DocumentDatabase: ObservableObject {
    @Published var documents: [Document] = []
    
    static let shared = DocumentDatabase()
    
    lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "DocumentModel")
        container.loadPersistentStores { _, error in
            if let error = error {
                print("❌ Core Data error: \(error.localizedDescription)")
            } else {
                print("📦 Core Data loaded successfully")
            }
        }
        return container
    }()
    
    var context: NSManagedObjectContext {
        return persistentContainer.viewContext
    }
    
    init() {
        loadDocuments()
    }
    
    // MARK: - CRUD Operations
    
    func saveDocument(_ document: Document) {
        print("📦 Database: Saving document '\(document.title)'")
        
        let entity = DocumentEntity(context: context)
        entity.id = document.id
        entity.title = document.title
        entity.content = document.content
        entity.ocrText = document.content // For now, content = OCR text
        entity.summary = document.summary
        entity.category = document.category.rawValue
        entity.keywordsResume = document.keywordsResume
        entity.dateCreated = document.dateCreated
        entity.documentType = document.type.rawValue
        
        // Store file data (PDF, image, etc.)
        if let pdfData = document.pdfData {
            entity.fileData = pdfData
        } else if let imageDataArray = document.imageData, let firstImage = imageDataArray.first {
            entity.fileData = firstImage
        }
        
        saveContext()
        loadDocuments() // Refresh the published documents array
    }
    
    func deleteDocument(_ document: Document) {
        print("📦 Database: Deleting document '\(document.title)'")
        
        let request: NSFetchRequest<DocumentEntity> = DocumentEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", document.id as CVarArg)
        
        do {
            let entities = try context.fetch(request)
            for entity in entities {
                context.delete(entity)
            }
            saveContext()
            loadDocuments()
        } catch {
            print("❌ Database: Delete error: \(error.localizedDescription)")
        }
    }
    
    func loadDocuments() {
        print("📦 Database: Loading documents from Core Data")
        
        let request: NSFetchRequest<DocumentEntity> = DocumentEntity.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \DocumentEntity.dateCreated, ascending: false)]
        
        do {
            let entities = try context.fetch(request)
            self.documents = entities.compactMap { entity in
                guard let type = Document.DocumentType(rawValue: entity.documentType) else {
                    return nil
                }
                
                // Convert file data back to appropriate format
                var imageData: [Data]? = nil
                var pdfData: Data? = nil
                
                if let fileData = entity.fileData {
                    if type == .pdf {
                        pdfData = fileData
                    } else if type == .image || type == .scanned {
                        imageData = [fileData]
                    }
                }
                
                return Document(
                    id: entity.id,
                    title: entity.title,
                    content: entity.ocrText.isEmpty ? entity.content : entity.ocrText,
                    summary: entity.summary,
                    category: Document.DocumentCategory(rawValue: entity.category) ?? .general,
                    keywordsResume: entity.keywordsResume,
                    dateCreated: entity.dateCreated,
                    type: type,
                    imageData: imageData,
                    pdfData: pdfData
                )
            }
            print("📦 Database: Loaded \(documents.count) documents")
        } catch {
            print("❌ Database: Load error: \(error.localizedDescription)")
        }
    }
    
    private func saveContext() {
        if context.hasChanges {
            do {
                try context.save()
                print("📦 Database: Context saved successfully")
            } catch {
                print("❌ Database: Save error: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - AI Query Support
    
    func getAllDocumentContent() -> String {
        return documents.map { document in
            """
            Document: \(document.title)
            Type: \(document.type.rawValue)
            Date: \(DateFormatter.localizedString(from: document.dateCreated, dateStyle: .short, timeStyle: .none))
            Summary: \(document.summary)
            
            Content:
            \(document.content)
            
            ---
            
            """
        }.joined()
    }
    
    func searchDocuments(query: String) -> [Document] {
        let lowercaseQuery = query.lowercased()
        return documents.filter { document in
            document.title.lowercased().contains(lowercaseQuery) ||
            document.content.lowercased().contains(lowercaseQuery) ||
            document.summary.lowercased().contains(lowercaseQuery)
        }
    }
}
