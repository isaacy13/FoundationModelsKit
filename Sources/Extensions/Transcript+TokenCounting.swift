//
//  Transcript+TokenCounting.swift
//  FoundationModelsTools
//
//  Token counting and context window management utilities for Foundation Models transcripts.
//  Uses Apple's guidance of 4.5 characters per token for estimation.
//

import Foundation
import FoundationModels

// MARK: - Constants

/// Apple's guidance: approximately 4.5 characters per token
private let charactersPerToken = 4.5

/// Safety buffer multiplier for conservative token estimates (25%)
private let safetyBufferMultiplier = 0.25

/// System overhead in tokens for context window calculations
private let systemOverheadTokens = 100

// MARK: - Token Counting Extensions

extension Transcript.Entry {
  /// Estimates the token count for this transcript entry.
  ///
  /// This property calculates tokens based on the entry type:
  /// - Instructions, prompts, and responses: Sum of all segment tokens
  /// - Tool calls: Tool name + arguments + overhead (5 tokens)
  /// - Tool output: Sum of segments + overhead (3 tokens)
  ///
  /// Uses Apple's guidance of 4.5 characters per token.
  public var estimatedTokenCount: Int {
    switch self {
    case .instructions(let instructions):
      return instructions.segments.reduce(0) { $0 + $1.estimatedTokenCount }

    case .prompt(let prompt):
      return prompt.segments.reduce(0) { $0 + $1.estimatedTokenCount }

    case .response(let response):
      return response.segments.reduce(0) { $0 + $1.estimatedTokenCount }

    case .toolCalls(let toolCalls):
      return toolCalls.reduce(0) { total, call in
        total + estimateTokens(from: call.toolName) +
        estimateTokens(from: call.arguments) + 5  // Call overhead
      }

    case .toolOutput(let output):
      return output.segments.reduce(0) { $0 + $1.estimatedTokenCount } + 3  // Output overhead

    @unknown default:
      // Return 0 for unknown entry types to avoid crashes
      return 0
    }
  }
}

extension Transcript.Segment {
  /// Estimates the token count for this transcript segment.
  ///
  /// Calculates tokens based on segment type:
  /// - Text segments: Character count divided by 4.5
  /// - Structured segments: JSON representation length divided by 4.5
  ///
  /// Uses Apple's guidance of 4.5 characters per token.
  public var estimatedTokenCount: Int {
    switch self {
    case .text(let textSegment):
      return estimateTokens(from: textSegment.content)

    case .structure(let structuredSegment):
      return estimateTokens(from: structuredSegment.content)

    @unknown default:
      // Return 0 for unknown segment types to avoid crashes
      return 0
    }
  }
}

extension Transcript {
  /// Estimates the total token count for all entries in this transcript.
  ///
  /// Returns the sum of estimated tokens across all transcript entries.
  /// Uses Apple's guidance of 4.5 characters per token.
  ///
  /// Example:
  /// ```swift
  /// let transcript = Transcript(...)
  /// let tokens = transcript.estimatedTokenCount
  /// print("Transcript uses approximately \(tokens) tokens")
  /// ```
  public var estimatedTokenCount: Int {
    return self.reduce(0) { $0 + $1.estimatedTokenCount }
  }

  /// Returns the estimated token count with a safety buffer.
  ///
  /// Adds a 25% buffer plus 100 tokens for system overhead to the base estimate.
  /// Use this for conservative token budgeting to avoid hitting context limits.
  ///
  /// Example:
  /// ```swift
  /// let transcript = Transcript(...)
  /// let safeTokens = transcript.safeEstimatedTokenCount
  /// if safeTokens < 4000 {
  ///     // Safe to continue conversation
  /// }
  /// ```
  public var safeEstimatedTokenCount: Int {
    let baseTokens = estimatedTokenCount
    let buffer = Int(Double(baseTokens) * safetyBufferMultiplier)
    let systemOverhead = systemOverheadTokens

    return baseTokens + buffer + systemOverhead
  }

  /// Checks if the transcript is approaching the token limit.
  ///
  /// - Parameters:
  ///   - threshold: The percentage of maxTokens at which to trigger (default: 0.70 or 70%)
  ///   - maxTokens: The maximum token limit for the model (default: 4096)
  ///
  /// - Returns: `true` if the safe estimated token count exceeds the threshold
  ///
  /// Example:
  /// ```swift
  /// let transcript = Transcript(...)
  /// if transcript.isApproachingLimit(threshold: 0.8, maxTokens: 4096) {
  ///     // Trim transcript or summarize conversation
  /// }
  /// ```
  public func isApproachingLimit(threshold: Double = 0.70, maxTokens: Int = 4096) -> Bool {
    let currentTokens = safeEstimatedTokenCount
    let limitThreshold = Int(Double(maxTokens) * threshold)
    return currentTokens > limitThreshold
  }

  /// Returns a subset of entries that fit within the specified token budget.
  ///
  /// This method implements a sliding window approach:
  /// 1. Always includes the first instructions entry (if present)
  /// 2. Adds the most recent entries that fit within the budget
  /// 3. Preserves conversation recency while respecting token limits
  ///
  /// - Parameter budget: The maximum number of tokens allowed
  /// - Returns: An array of entries that fit within the budget
  ///
  /// Example:
  /// ```swift
  /// let transcript = Transcript(...)
  /// let trimmed = transcript.entriesWithinTokenBudget(2000)
  /// let newTranscript = Transcript(trimmed)
  /// ```
  public func entriesWithinTokenBudget(_ budget: Int) -> [Transcript.Entry] {
    var result: [Transcript.Entry] = []
    var tokenCount = 0

    // Always include instructions if present
    if let instructions = self.first(where: {
      if case .instructions = $0 { return true }
      return false
    }) {
      result.append(instructions)
      tokenCount += instructions.estimatedTokenCount
    }

    // Add most recent entries that fit
    let nonInstructionEntries = self.filter { entry in
      if case .instructions = entry { return false }
      return true
    }

    let insertionIndex = result.isEmpty ? 0 : 1
    for entry in nonInstructionEntries.reversed() {
      let entryTokens = entry.estimatedTokenCount
      if tokenCount + entryTokens > budget { break }

      result.insert(entry, at: insertionIndex)
      tokenCount += entryTokens
    }

    return result
  }
}

// MARK: - Token Estimation Utilities

/// Estimates token count from a string using Apple's guidance: 4.5 characters per token.
///
/// - Parameter text: The text to estimate tokens for
/// - Returns: Estimated token count (minimum 1 for non-empty strings)
///
/// Example:
/// ```swift
/// let tokens = estimateTokens(from: "Hello, world!")
/// print("Token count: \(tokens)")  // Prints approximately 3
/// ```
public func estimateTokens(from text: String) -> Int {
  guard !text.isEmpty else { return 0 }

  let characterCount = text.count
  let tokensPerChar = 1.0 / charactersPerToken

  return max(1, Int(ceil(Double(characterCount) * tokensPerChar)))
}

/// Estimates token count from structured content (GeneratedContent) by converting to JSON.
///
/// - Parameter content: The GeneratedContent to estimate tokens for
/// - Returns: Estimated token count based on JSON representation length
///
/// Example:
/// ```swift
/// let content = GeneratedContent(...)
/// let tokens = estimateTokens(from: content)
/// ```
public func estimateTokens(from content: GeneratedContent) -> Int {
  let jsonString = content.jsonString
  let characterCount = jsonString.count
  let tokensPerChar = 1.0 / charactersPerToken

  return max(1, Int(ceil(Double(characterCount) * tokensPerChar)))
}
