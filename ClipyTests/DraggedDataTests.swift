import Foundation
import Testing
@testable import Clipy

@Suite
struct DraggedDataTests {
    @Test
    func archiveData() throws {
        let draggedData = CPYDraggedData(type: .folder, folderIdentifier: UUID().uuidString, snippetIdentifier: nil, index: 10)
        let data = try #require(try? NSKeyedArchiver.archivedData(withRootObject: draggedData, requiringSecureCoding: false))

        let unarchiver = try #require(try? NSKeyedUnarchiver(forReadingFrom: data))
        unarchiver.requiresSecureCoding = false
        let unarchiveData = try #require(unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? CPYDraggedData)
        #expect(unarchiveData.type == draggedData.type)
        #expect(unarchiveData.folderIdentifier == draggedData.folderIdentifier)
        #expect(unarchiveData.snippetIdentifier == nil)
        #expect(unarchiveData.index == draggedData.index)
    }
}
