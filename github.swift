#!/usr/bin/env xcrun swift

import Foundation

var token = ""

struct System {

  static func execute(command: String, _ arguments: String? = nil, closure: ((output: String) -> Void)?) -> Void {
    guard let command = which(command) else { return }
    return task(command, arguments, closure)
  }

  private static func which(command: String, _ arguments: String? = nil) -> String? {
    let task = NSTask()
    task.launchPath = "/usr/bin/which"
    task.arguments = [command]

    let pipe = NSPipe()
    task.standardOutput = pipe
    task.launch()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = NSString(data: data, encoding: NSUTF8StringEncoding) as String?

    return output?.componentsSeparatedByString("\n").first
  }

  private static func task(command: String, _ arguments: String? = nil, _ closure: ((output: String) -> Void)?) -> Void {
    let task = NSTask()
    task.launchPath = command

    if let arguments = arguments where !arguments.isEmpty {
      task.arguments = arguments.componentsSeparatedByString(" ")
    }

    let stdOut = NSPipe()
    task.standardOutput = stdOut
    let stdErr = NSPipe()
    task.standardError = stdErr

    let handler =  { (file: NSFileHandle!) -> Void in
      let data = file.availableData
      guard let output = NSString(data: data, encoding: NSUTF8StringEncoding)
        else { return }
      closure?(output: output.componentsSeparatedByString("\n").first!)
    }

    stdOut.fileHandleForReading.readabilityHandler = handler
    stdErr.fileHandleForReading.readabilityHandler = handler

    task.terminationHandler = { (task: NSTask?) -> () in
      stdErr.fileHandleForReading.readabilityHandler = nil
      stdOut.fileHandleForReading.readabilityHandler = nil
    }

    task.launch()
    task.waitUntilExit()
  }
}

var keepAlive = false

struct Network {

  static func request(resource: String, completion: (json: AnyObject) -> Void) {
    guard let url = NSURL(string: resource)
      else { print("Faulty URL: \(resource)"); return }

    keepAlive = true

    let request = NSMutableURLRequest(URL: url)
    request.HTTPMethod = "GET"

    let headers: [String : String] = [
      "Content-Type" : "application/json",
      "Authorization" : "token \(token)",
    ]

    for (key, value) in headers {
      request.addValue(value, forHTTPHeaderField: key)
    }

    let session = NSURLSession.sharedSession()
    session.dataTaskWithRequest(request) { data, response, error in
      guard let responseHTTP = response as? NSHTTPURLResponse,
        data = data
        where responseHTTP.statusCode == 200 || responseHTTP.statusCode == 201
        else { keepAlive = false; return }

      do {
        let json = try NSJSONSerialization.JSONObjectWithData(data, options: NSJSONReadingOptions.AllowFragments)

        // JSON Array
        if let json = json as? [[String : AnyObject]] {
          completion(json: json)
        // JSON Dictionary
        } else if let json = json as? [String : AnyObject] {
          completion(json: json)
        }
      } catch {
        print(error)
      }
    }.resume()
  }
}

keepAlive = true

// Get github token
System.execute("cat", ".token") { output in
  guard output.characters.count > 0 else { return }
  token = output

  // Get current branch
  System.execute("git", "rev-parse --abbrev-ref HEAD") { output in
    let branch = output

    // Get current origin
    System.execute("git", "config --get remote.origin.url") { output in
      guard let url = NSURL(string: output) else { return }
      let components = url.pathComponents
      guard let owner = components?.first?.componentsSeparatedByString(":").last else { return }
      guard let repo = components?.last?.componentsSeparatedByString(".").first else { return }

      // Fetch pull requests for current repo
      Network.request("https://api.github.com/repos/\(owner)/\(repo)/pulls") { response in
        guard let json = response as? [[String : AnyObject]],
          pullrequest = json
          .filter({ (($0["head"] as! [String : AnyObject])["label"] as? String) == "\(owner):\(branch)" })
          .first
        else {
          keepAlive = false
          return
        }

        guard let number = pullrequest["number"] as? Int else { return }

        // Fetch comments for current pull request on repo
        Network.request("https://api.github.com/repos/\(owner)/\(repo)/pulls/\(number)/comments") { response in
          guard let json = response as? [[String : AnyObject]] else { return }

          print(json)
          keepAlive = false
        }
      }
    }
  }
}

// Add run loop to keep script alive while running async operations
let runLoop = NSRunLoop.currentRunLoop()
while keepAlive &&
  runLoop.runMode(NSDefaultRunLoopMode, beforeDate: NSDate(timeIntervalSinceNow: 0.1)) {
}
