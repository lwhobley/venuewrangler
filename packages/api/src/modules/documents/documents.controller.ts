import {
  BadRequestException,
  Body,
  Controller,
  Delete,
  ForbiddenException,
  Get,
  Logger,
  NotFoundException,
  Param,
  Post,
  ServiceUnavailableException,
} from '@nestjs/common';
import { IsIn, IsString, MaxLength } from 'class-validator';
import { canManageVenue } from '../../auth/roles';
import { RequireSubscription } from '../../billing/require-subscription.decorator';
import {
  assertAllowedDocumentBytes,
  MAX_DOCUMENT_BYTES,
  safeDocumentFileName,
} from '../../common/document-bytes';
import { PrismaService } from '../../prisma/prisma.service';
import { VenueScope } from '../../venue/venue-scope.decorator';
import type { VenueScopedRequest } from '../../venue/venue-scope.interceptor';
import { MediaCleanupService } from '../media-cleanup/media-cleanup.service';
import { S3DocumentService } from './s3-document.service';
import { DocumentMalwareScannerService } from './document-malware-scanner.service';
import { Audited } from '../audit/audited.decorator';

const DOCUMENT_CATEGORIES = ['sop', 'manual', 'recipe', 'menu', 'training', 'form', 'other'] as const;
type DocumentCategoryValue = (typeof DOCUMENT_CATEGORIES)[number];
type Scope = VenueScopedRequest['venueScope'];

// sop/manual/recipe/menu/training are the working-floor library every staff
// member needs. 'form' and 'other' are the catch-all categories that end up
// holding HR paperwork, so they're manager-only -- unlike the rest of this
// controller, which is deliberately staff-readable.
const MANAGER_ONLY_CATEGORIES: ReadonlySet<DocumentCategoryValue> = new Set(['form', 'other']);

class UploadDocumentDto {
  @IsString()
  @MaxLength(120)
  title!: string;

  @IsString()
  @MaxLength(220)
  fileName!: string;

  @IsString()
  @MaxLength(120)
  mimeType!: string;

  @IsString()
  @IsIn(DOCUMENT_CATEGORIES)
  category!: DocumentCategoryValue;

  @IsString()
  @MaxLength(15_000_000)
  dataBase64!: string;
}

function requireScope(scope: Scope): asserts scope is NonNullable<Scope> {
  if (!scope) throw new ForbiddenException('No venue profile found');
}

function requireManager(scope: Scope): asserts scope is NonNullable<Scope> {
  requireScope(scope);
  if (!canManageVenue(scope.role, scope.allAccess)) throw new ForbiddenException('Only managers can manage documents');
}

@Controller('v1/documents')
export class DocumentsController {
  private readonly logger = new Logger(DocumentsController.name);
  constructor(
    private readonly prisma: PrismaService,
    private readonly storage: S3DocumentService,
    private readonly malwareScanner: DocumentMalwareScannerService,
    private readonly mediaCleanup: MediaCleanupService,
  ) {}

  @RequireSubscription('active')
  @Get()
  async list(@VenueScope() scope: Scope) {
    requireScope(scope);
    // Safety cap, not organic pagination: the document library is expected to
    // stay well under this for any real venue. Without a bound this query
    // grows without limit over a venue's lifetime.
    const LIST_CAP = 1000;
    const isManager = canManageVenue(scope.role, scope.allAccess);
    const documents = await this.prisma.venueDocument.findMany({
      where: {
        venueId: scope.venueId,
        ...(isManager ? {} : { category: { notIn: Array.from(MANAGER_ONLY_CATEGORIES) } }),
      },
      orderBy: [{ createdAt: 'desc' }, { id: 'desc' }],
      include: { uploadedBy: { select: { fullName: true } } },
      take: LIST_CAP,
    });
    if (documents.length === LIST_CAP) {
      this.logger.warn(`Document list for venue ${scope.venueId} hit the ${LIST_CAP}-row cap; older documents are not shown.`);
    }
    return documents.map((document) => ({
      id: document.id,
      _id: document.id,
      title: document.title,
      fileName: document.fileName,
      category: document.category,
      mimeType: document.mimeType,
      sizeBytes: document.sizeBytes,
      uploadedBy: document.uploadedBy?.fullName ?? null,
      createdAt: document.createdAt.getTime(),
      updatedAt: document.updatedAt.getTime(),
    }));
  }

  @RequireSubscription('active')
  @Audited('document.upload', { entityType: 'document', summary: 'Uploaded venue document' })
  @Post()
  async upload(@VenueScope() scope: Scope, @Body() body: UploadDocumentDto) {
    requireManager(scope);
    const title = body.title.trim();
    if (!title) throw new BadRequestException('Document title is required');
    const fileName = safeDocumentFileName(body.fileName);
    const encoded = body.dataBase64.replace(/\s/g, '');
    if (!encoded || encoded.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(encoded)) {
      throw new BadRequestException('Document data is not valid base64');
    }
    const data = Buffer.from(encoded, 'base64');
    if (data.length === 0) throw new BadRequestException('Document is empty');
    if (data.length > MAX_DOCUMENT_BYTES) throw new BadRequestException('Document is too large (max 10MB)');
    const mimeType = assertAllowedDocumentBytes(data, body.mimeType, fileName);
    await this.malwareScanner.assertClean(data);

    let s3Key: string;
    try {
      s3Key = await this.storage.upload(data, mimeType, scope.venueId);
    } catch (error) {
      this.logger.error(`Document upload storage failed for venue ${scope.venueId}`, error instanceof Error ? error.stack : undefined);
      throw new ServiceUnavailableException('Document storage is temporarily unavailable. Please try again.');
    }
    try {
      const document = await this.prisma.venueDocument.create({
        data: {
          venueId: scope.venueId,
          title,
          fileName,
          category: body.category,
          mimeType,
          sizeBytes: data.length,
          s3Key,
          uploadedById: scope.profileId,
        },
      });
      return { id: document.id, _id: document.id };
    } catch (error) {
      await this.storage.delete(s3Key).catch(() => undefined);
      throw error;
    }
  }

  @RequireSubscription('active')
  @Audited('document.access', { entityType: 'document', summary: 'Generated access URL for venue document' })
  @Post(':id/access')
  async access(@VenueScope() scope: Scope, @Param('id') id: string) {
    requireScope(scope);
    const document = await this.prisma.venueDocument.findFirst({
      where: { id, venueId: scope.venueId },
    });
    if (!document) throw new NotFoundException('Document not found');
    if (
      MANAGER_ONLY_CATEGORIES.has(document.category as DocumentCategoryValue) &&
      !canManageVenue(scope.role, scope.allAccess)
    ) {
      throw new NotFoundException('Document not found');
    }
    let url: string;
    try {
      url = await this.storage.getPresignedUrl(document.s3Key, document.fileName, document.mimeType);
    } catch (error) {
      this.logger.error(`Document access storage failed for document ${document.id}`, error instanceof Error ? error.stack : undefined);
      throw new ServiceUnavailableException('Document storage is temporarily unavailable. Please try again.');
    }
    return { url, expiresInSeconds: 120 };
  }

  @RequireSubscription('active')
  @Audited('document.delete', { entityType: 'document', summary: 'Deleted venue document' })
  @Delete(':id')
  async remove(@VenueScope() scope: Scope, @Param('id') id: string) {
    requireManager(scope);
    const document = await this.prisma.venueDocument.findFirst({
      where: { id, venueId: scope.venueId },
    });
    if (!document) throw new NotFoundException('Document not found');
    // Queue the S3 delete in the same transaction as the row delete rather
    // than deleting from S3 first. Previously a DB failure after a successful
    // S3 delete left a row pointing at a missing object (download 404s), and a
    // failed S3 delete threw before the row was removed. The outbox makes the
    // pair atomic and retries the S3 side until it succeeds.
    const jobId = await this.prisma.$transaction(async (tx) => {
      const job = await tx.objectDeletionJob.create({
        data: { objectKeys: [document.s3Key] },
        select: { id: true },
      });
      await tx.venueDocument.delete({ where: { id: document.id } });
      return job.id;
    });
    void this.mediaCleanup.processJob(jobId).catch((error) => {
      this.logger.error(`Document media cleanup job ${jobId} failed:`, error instanceof Error ? error.stack : String(error));
    });
    return { ok: true };
  }
}
