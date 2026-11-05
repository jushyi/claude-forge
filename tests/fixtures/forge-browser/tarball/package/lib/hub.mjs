export class Hub {
  async start() {
    try {
      await this.becomeOwner();
    } catch (err) {
      await this.becomePeer();
    }
    return this;
  }

  async send() {
    if (this.owner) {
      if (!this.extension) throw new Error('not connected');
    } else if (!this.peerSocket) {
      await new Promise((r) => setTimeout(r, 1500));
      if (!this.peerSocket) throw new Error('Reconnecting to the browser bridge; retry in a moment.');
    }
    return this.peerSocket;
  }
}
