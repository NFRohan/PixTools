package services

import (
	"bytes"
	"context"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

type S3Service struct {
	client     *s3.Client
	presignCli *s3.PresignClient
	bucket     string
}

// NewS3Service creates a new AWS S3 client
func NewS3Service(ctx context.Context, region, endpoint, accessKey, secretKey, bucket string) (*S3Service, error) {
	var cfg aws.Config
	var err error

	// If local/minio endpoint is provided, use static credentials and custom endpoint
	if endpoint != "" {
		customResolver := aws.EndpointResolverWithOptionsFunc(func(service, rgn string, options ...interface{}) (aws.Endpoint, error) {
			if service == s3.ServiceID && rgn == region {
				return aws.Endpoint{
					URL:               endpoint,
					SigningRegion:     region,
					HostnameImmutable: true, // required for minio/localstack
				}, nil
			}
			return aws.Endpoint{}, &aws.EndpointNotFoundError{}
		})

		cfg, err = config.LoadDefaultConfig(ctx,
			config.WithRegion(region),
			config.WithEndpointResolverWithOptions(customResolver),
			config.WithCredentialsProvider(credentials.NewStaticCredentialsProvider(accessKey, secretKey, "")),
		)
	} else {
		// Production AWS, uses IAM roles natively
		cfg, err = config.LoadDefaultConfig(ctx, config.WithRegion(region))
	}

	if err != nil {
		return nil, fmt.Errorf("unable to load SDK config: %w", err)
	}

	client := s3.NewFromConfig(cfg, func(o *s3.Options) {
		if endpoint != "" {
			o.UsePathStyle = true // Needed for LocalStack/Minio
		}
	})

	presignCli := s3.NewPresignClient(client)

	return &S3Service{
		client:     client,
		presignCli: presignCli,
		bucket:     bucket,
	}, nil
}

// UploadRaw synchronously uploads a raw image byte slice to S3 and returns the object key
func (s *S3Service) UploadRaw(ctx context.Context, fileBytes []byte, originalFilename, jobID string) (string, error) {
	key := fmt.Sprintf("raw/%s/%s", jobID, originalFilename)

	_, err := s.client.PutObject(ctx, &s3.PutObjectInput{
		Bucket: aws.String(s.bucket),
		Key:    aws.String(key),
		Body:   bytes.NewReader(fileBytes),
	})
	if err != nil {
		return "", fmt.Errorf("failed to upload raw file to S3: %w", err)
	}

	return key, nil
}

// GeneratePresignedURL generates a temporary download link
func (s *S3Service) GeneratePresignedURL(ctx context.Context, key, downloadFilename string) (string, error) {
	request, err := s.presignCli.PresignGetObject(ctx, &s3.GetObjectInput{
		Bucket:                     aws.String(s.bucket),
		Key:                        aws.String(key),
		ResponseContentDisposition: aws.String(fmt.Sprintf(`attachment; filename="%s"`, downloadFilename)),
	}, func(opts *s3.PresignOptions) {
		opts.Expires = 24 * time.Hour
	})

	if err != nil {
		return "", fmt.Errorf("failed to generate presigned URL: %w", err)
	}

	return request.URL, nil
}

// ObjectExists checks if an object exists in the S3 bucket
func (s *S3Service) ObjectExists(ctx context.Context, key string) bool {
	_, err := s.client.HeadObject(ctx, &s3.HeadObjectInput{
		Bucket: aws.String(s.bucket),
		Key:    aws.String(key),
	})
	return err == nil
}

// GetArchiveKey returns the standard path for a job's zip bundle
func (s *S3Service) GetArchiveKey(jobID string) string {
	return fmt.Sprintf("processed/%s/bundle.zip", jobID)
}
