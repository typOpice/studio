import Foundation

/// How Studio shows each GUI class: its icon, and a short name for the ribbon.
extension GuiObject.Kind {
    var symbolName: String {
        switch self {
        case .screenGui: return "rectangle.on.rectangle"
        case .billboardGui: return "text.bubble"
        case .frame: return "square"
        case .scrollingFrame: return "scroll"
        case .textLabel: return "textformat"
        case .textButton: return "button.horizontal"
        case .textBox: return "character.cursor.ibeam"
        case .imageLabel: return "photo"
        case .imageButton: return "photo.badge.plus"
        case .uiCorner: return "square.dashed"
        case .uiPadding: return "square.inset.filled"
        case .uiListLayout: return "list.bullet"
        case .uiStroke: return "square.dashed.inset.filled"
        case .uiGradient: return "circle.lefthalf.filled"
        case .uiGridLayout: return "square.grid.3x3"
        case .uiAspectRatioConstraint: return "aspectratio"
        case .uiSizeConstraint: return "arrow.up.left.and.arrow.down.right"
        case .uiTextSizeConstraint: return "textformat.size"
        }
    }

    var shortName: String {
        switch self {
        case .screenGui: return "ScreenGui"
        case .billboardGui: return "Billboard"
        case .frame: return "Frame"
        case .scrollingFrame: return "Scrolling"
        case .textLabel: return "Text"
        case .textButton: return "Button"
        case .textBox: return "TextBox"
        case .imageLabel: return "Image"
        case .imageButton: return "ImageButton"
        case .uiCorner: return "Corner"
        case .uiPadding: return "Padding"
        case .uiListLayout: return "List"
        case .uiStroke: return "Stroke"
        case .uiGradient: return "Gradient"
        case .uiGridLayout: return "Grid"
        case .uiAspectRatioConstraint: return "Aspect"
        case .uiSizeConstraint: return "Size Limit"
        case .uiTextSizeConstraint: return "Text Limit"
        }
    }

    /// What can be inserted inside a GUI object from the Explorer and the ribbon.
    static let insertableObjects: [GuiObject.Kind] = [.frame, .textLabel, .textButton, .textBox, .imageLabel,
                                                      .imageButton, .scrollingFrame]
    static let insertableModifiers: [GuiObject.Kind] = [.uiCorner, .uiPadding, .uiStroke, .uiGradient, .uiListLayout,
                                                        .uiGridLayout, .uiAspectRatioConstraint, .uiSizeConstraint,
                                                        .uiTextSizeConstraint]
}
