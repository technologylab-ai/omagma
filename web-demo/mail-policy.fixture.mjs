// Explicit independent test data. Production reads the compiled Zig manifest.
export const decoderRevisionFixture = 5;
export const mailPolicyFixture = Object.freeze({
  displayNameBytes: 1024, incomingAddressBytes: 1024, outgoingAddressBytes: 512,
  subjectTextBytes: 16384, subjectPrefixBytes: 16, subjectBytes: 16400, snippetBytes: 16384,
  filenameBytes: 512, headerValueBytes: 65536, headersBytes: 131072,
  headerCount: 256, referenceCount: 256, referencesBytes: 65536, messageIdBytes: 985,
  incomingRecipients: 1024,
});
