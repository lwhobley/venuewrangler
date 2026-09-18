import { NotFoundException } from '@nestjs/common';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import type { GetObjectCommandOutput } from '@aws-sdk/client-s3';
import type { Response } from 'express';

/** Call only after validating the media access token and venue. */
export function streamPrivateImage(object: GetObjectCommandOutput, res: Response) {
  if (!object.Body) throw new NotFoundException('Image content not found');
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('Cross-Origin-Resource-Policy', 'cross-origin');
  res.setHeader('Content-Type', object.ContentType ?? 'application/octet-stream');
  return pipeline(object.Body as Readable, res);
}
