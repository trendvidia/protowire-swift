import Foundation

extension SBE {
    /// A template for an SBE field.
    public struct FieldTemplate {
        /// The name of the field.
        public var name: String
        /// The offset of the field in the block.
        public var offset: Int
        /// The size of the field in bytes.
        public var size: Int
        /// The encoding of the field.
        public var encoding: Encoding?
        /// The composite fields if this is a composite type.
        public var composite: [FieldTemplate]?
        internal var compositeView: ViewSchema?
        
        /// Initializes a new field template.
        public init(name: String, offset: Int, size: Int, encoding: Encoding? = nil, composite: [FieldTemplate]? = nil) {
            self.name = name
            self.offset = offset
            self.size = size
            self.encoding = encoding
            self.composite = composite
        }
    }

    /// A template for an SBE group.
    public struct GroupTemplate {
        /// The name of the group.
        public var name: String
        /// The length of each block in the group.
        public var blockLength: Int
        /// The fields in the group.
        public var fields: [FieldTemplate]
        internal var entryView: ViewSchema?
        
        /// Initializes a new group template.
        public init(name: String, blockLength: Int, fields: [FieldTemplate]) {
            self.name = name
            self.blockLength = blockLength
            self.fields = fields
        }
    }

    /// A template for an SBE message.
    public class MessageTemplate {
        /// The template ID.
        public var templateID: UInt16
        /// The schema ID.
        public var schemaID: UInt16
        /// The version.
        public var version: UInt16
        /// The length of the root block.
        public var blockLength: Int
        /// The fields in the root block.
        public var fields: [FieldTemplate]
        /// The groups in the message.
        public var groups: [GroupTemplate]
        internal var view: ViewSchema?
        
        /// Initializes a new message template.
        public init(templateID: UInt16, schemaID: UInt16, version: UInt16, blockLength: Int, fields: [FieldTemplate], groups: [GroupTemplate] = []) {
            self.templateID = templateID
            self.schemaID = schemaID
            self.version = version
            self.blockLength = blockLength
            self.fields = fields
            self.groups = groups
            self.view = ViewSchema(fields: fields, groups: groups)
        }
    }

    internal struct ViewSchema {
        var fieldMap: [String: FieldTemplate]
        var groupOrder: [String]
        var groupMap: [String: ViewSchema]

        init(fields: [FieldTemplate], groups: [GroupTemplate]) {
            var fm: [String: FieldTemplate] = [:]
            for i in 0..<fields.count {
                var ft = fields[i]
                if let comp = ft.composite {
                    ft.compositeView = ViewSchema(fields: comp, groups: [])
                }
                fm[ft.name] = ft
            }
            self.fieldMap = fm
            
            self.groupOrder = groups.map { $0.name }
            var gm: [String: ViewSchema] = [:]
            for g in groups {
                gm[g.name] = ViewSchema(fields: g.fields, groups: [])
            }
            self.groupMap = gm
        }
    }
}
