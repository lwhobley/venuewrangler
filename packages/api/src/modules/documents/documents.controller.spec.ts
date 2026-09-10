import { BadRequestException, ForbiddenException, NotFoundException } from '@nestjs/common';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { DocumentsController } from './documents.controller';

const managerScope = { venueId: 'venue-1', profileId: 'manager-1', role: 'manager', allAccess: false } as any;
const staffScope = { venueId: 'venue-1', profileId: 'staff-1', role: 'staff', allAccess: false } as any;

describe('DocumentsController', () => {
  const prisma = {
    venueDocument: {
      findMany: vi.fn(),
      findFirst: vi.fn(),
      create: vi.fn(),
      delete: vi.fn(),
    },
    objectDeletionJob: {
      create: vi.fn().mockResolvedValue({ id: 'delete-job-1' }),
    },
    $transaction: vi.fn(),
  } as any;
  const storage = {
    upload: vi.fn(),
    getPresignedUrl: vi.fn(),
    delete: vi.fn(),
  } as any;
  const mediaCleanup = { processJob: vi.fn().mockResolvedValue(true) } as any;
  const malwareScanner = { assertClean: vi.fn().mockResolvedValue(undefined) } as any;
  prisma.$transaction.mockImplementation((callback: (tx: typeof prisma) => unknown) => callback(prisma));
  const controller = new DocumentsController(prisma, storage, malwareScanner, mediaCleanup);

  beforeEach(() => vi.clearAllMocks());

  it('lists only documents from the active venue', async () => {
    prisma.venueDocument.findMany.mockResolvedValue([{
      id: 'doc-1', title: 'Opening SOP', fileName: 'opening.pdf', category: 'sop', mimeType: 'application/pdf',
      sizeBytes: 120, uploadedBy: { fullName: 'Morgan' }, createdAt: new Date(1000), updatedAt: new Date(2000),
    }]);
    const result = await controller.list(staffScope);
    expect(prisma.venueDocument.findMany).toHaveBeenCalledWith(expect.objectContaining({
      where: { venueId: 'venue-1', category: { notIn: ['form', 'other'] } },
    }));
    expect(result[0]).toMatchObject({ id: 'doc-1', uploadedBy: 'Morgan', createdAt: 1000 });
  });

  it('does not hide form/other documents from managers', async () => {
    prisma.venueDocument.findMany.mockResolvedValue([]);
    await controller.list(managerScope);
    expect(prisma.venueDocument.findMany).toHaveBeenCalledWith(expect.objectContaining({
      where: { venueId: 'venue-1' },
    }));
  });

  it('allows managers to upload validated documents', async () => {
    storage.upload.mockResolvedValue('documents/venue-1/key');
    prisma.venueDocument.create.mockResolvedValue({ id: 'doc-1' });
    const result = await controller.upload(managerScope, {
      title: ' Opening SOP ', fileName: 'opening.pdf', mimeType: 'application/pdf', category: 'sop',
      dataBase64: Buffer.from('%PDF-1.7\nbody').toString('base64'),
    });
    expect(storage.upload).toHaveBeenCalledWith(expect.any(Buffer), 'application/pdf', 'venue-1');
    expect(malwareScanner.assertClean).toHaveBeenCalledWith(expect.any(Buffer));
    expect(prisma.venueDocument.create).toHaveBeenCalledWith({ data: expect.objectContaining({ title: 'Opening SOP', venueId: 'venue-1' }) });
    expect(result).toEqual({ id: 'doc-1', _id: 'doc-1' });
  });

  it('blocks staff uploads and invalid files', async () => {
    await expect(controller.upload(staffScope, {} as any)).rejects.toThrow(ForbiddenException);
    await expect(controller.upload(managerScope, {
      title: 'Bad', fileName: 'bad.pdf', mimeType: 'application/pdf', category: 'manual',
      dataBase64: Buffer.from('not pdf').toString('base64'),
    })).rejects.toThrow(BadRequestException);
  });

  it('does not issue access links across venues', async () => {
    prisma.venueDocument.findFirst.mockResolvedValue(null);
    await expect(controller.access(staffScope, 'doc-other')).rejects.toThrow(NotFoundException);
    expect(prisma.venueDocument.findFirst).toHaveBeenCalledWith({ where: { id: 'doc-other', venueId: 'venue-1' } });
  });

  it('issues a 120-second presigned access link for an active venue document', async () => {
    prisma.venueDocument.findFirst.mockResolvedValue({
      id: 'doc-1', venueId: 'venue-1', s3Key: 'documents/venue-1/key', fileName: 'sop.pdf', mimeType: 'application/pdf',
    });
    storage.getPresignedUrl.mockResolvedValue('https://s3.example.com/presigned-sop.pdf');
    const result = await controller.access(staffScope, 'doc-1');
    expect(storage.getPresignedUrl).toHaveBeenCalledWith('documents/venue-1/key', 'sop.pdf', 'application/pdf');
    expect(result).toEqual({ url: 'https://s3.example.com/presigned-sop.pdf', expiresInSeconds: 120 });
  });

  it('404s staff out of a manager-only category document, same as a missing one', async () => {
    prisma.venueDocument.findFirst.mockResolvedValue({
      id: 'doc-1', venueId: 'venue-1', category: 'form', s3Key: 'documents/venue-1/key', fileName: 'w4.pdf', mimeType: 'application/pdf',
    });
    await expect(controller.access(staffScope, 'doc-1')).rejects.toThrow(NotFoundException);
    expect(storage.getPresignedUrl).not.toHaveBeenCalled();
  });

  it('lets managers access a manager-only category document', async () => {
    prisma.venueDocument.findFirst.mockResolvedValue({
      id: 'doc-1', venueId: 'venue-1', category: 'form', s3Key: 'documents/venue-1/key', fileName: 'w4.pdf', mimeType: 'application/pdf',
    });
    storage.getPresignedUrl.mockResolvedValue('https://s3.example.com/presigned-w4.pdf');
    const result = await controller.access(managerScope, 'doc-1');
    expect(result).toEqual({ url: 'https://s3.example.com/presigned-w4.pdf', expiresInSeconds: 120 });
  });

  it('lets managers delete a venue document through the durable cleanup outbox', async () => {
    prisma.venueDocument.findFirst.mockResolvedValue({ id: 'doc-1', s3Key: 'documents/venue-1/0123456789abcdef0123456789abcdef' });
    await expect(controller.remove(managerScope, 'doc-1')).resolves.toEqual({ ok: true });
    expect(prisma.objectDeletionJob.create).toHaveBeenCalledWith({
      data: { objectKeys: ['documents/venue-1/0123456789abcdef0123456789abcdef'] },
      select: { id: true },
    });
    expect(prisma.venueDocument.delete).toHaveBeenCalledWith({ where: { id: 'doc-1' } });
    expect(mediaCleanup.processJob).toHaveBeenCalledWith('delete-job-1');
  });
});
