/**
 * Tae Won Ha - http://taewon.de - @hataewon
 * See LICENSE
 */

import Foundation

class Token: Equatable {}

func == (left: Token, right: Token) -> Bool {
  return left === right
}

class FileItem : CustomStringConvertible {

  let url: URL
  let dir: Bool
  let hidden: Bool
  let package: Bool

  /// When nil, then it has never been fnmatch'ed.
  weak var ignoreToken: Token?
  var ignore = false

  var needsScanChildren = false
  var childrenScanned = false
  
  var children: [FileItem] = []

  var description: String {
    return "<FileItem: \(self.url), dir=\(self.dir), hidden=\(self.hidden), package=\(self.package)"
      + "needsScan=\(self.needsScanChildren), childrenScanned=\(self.childrenScanned), "
      + "ignore=\(self.ignore), ignoreToken=\(self.ignoreToken), "
      + "children=\(self.children.count)>"
  }

  init(_ url: URL) {
    self.url = url
    self.dir = url.dir
    self.hidden = url.hidden
    self.package = url.package
  }

  func removeChild(withUrl url: URL) {
    guard let idx = self.children.index(where: { $0.url == url }) else {
      return
    }

    self.children.remove(at: idx)
  }
}
