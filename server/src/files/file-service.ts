export class FileService {
  listCapabilities() {
    return {
      fileRead: false,
      message: "File browsing is intentionally disabled for MVP"
    };
  }
}
