import { DeleteObjectCommand, GetObjectCommand, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { randomBytes } from 'crypto';

@Injectable()
export class S3DocumentService {
  private readonly s3: S3Client;
  private readonly bucket: string;

  constructor(config: ConfigService) {
    this.s3 = new S3Client({
      region: config.get<string>('AWS_REGION', 'us-east-1'),
      credentials: {
        accessKeyId: config.getOrThrow<string>('AWS_ACCESS_KEY_ID'),
        secretAccessKey: config.getOrThrow<string>('AWS_SECRET_ACCESS_KEY'),
      },
    });
    this.bucket = config.getOrThrow<string>('AWS_S3_BUCKET');
  }

  async upload(buffer: Buffer, mimeType: string, venueId: string): Promise<string> {
    const key = `documents/${venueId}/${randomBytes(16).toString('hex')}`;
    await this.s3.send(new PutObjectCommand({
      Bucket: this.bucket,
      Key: key,
      Body: buffer,
      ContentType: mimeType,
      ServerSideEncryption: 'AES256',
    }));
    return key;
  }

  async getPresignedUrl(key: string, fileName: string, mimeType: string, expiresInSeconds = 120): Promise<string> {
    const isSafeImage = mimeType.startsWith('image/') && mimeType !== 'image/svg+xml';
    const isPdf = mimeType === 'application/pdf';
    const disposition = isSafeImage || isPdf ? 'inline' : 'attachment';
    const safeName = fileName.replace(/["\\\r\n]/g, '_');

    return getSignedUrl(
      this.s3,
      new GetObjectCommand({
        Bucket: this.bucket,
        Key: key,
        ResponseContentType: isSafeImage || isPdf ? mimeType : 'application/octet-stream',
        ResponseContentDisposition: `${disposition}; filename="${safeName}"`,
      }),
      { expiresIn: expiresInSeconds },
    );
  }

  async delete(key: string): Promise<void> {
    await this.s3.send(new DeleteObjectCommand({ Bucket: this.bucket, Key: key }));
  }
}
