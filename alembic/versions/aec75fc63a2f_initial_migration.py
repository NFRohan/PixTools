"""Initial migration

Revision ID: aec75fc63a2f
Revises:
Create Date: 2026-02-22 00:46:29.084194

"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = "aec75fc63a2f"
down_revision: Union[str, Sequence[str], None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


JOB_STATUS_VALUES = (
    "PENDING",
    "PROCESSING",
    "COMPLETED",
    "FAILED",
    "COMPLETED_WEBHOOK_FAILED",
)


def _table_exists(bind, table_name: str) -> bool:
    inspector = sa.inspect(bind)
    return table_name in inspector.get_table_names()


def _index_exists(bind, table_name: str, index_name: str) -> bool:
    inspector = sa.inspect(bind)
    indexes = inspector.get_indexes(table_name)
    return any(index["name"] == index_name for index in indexes)


def _column_exists(bind, table_name: str, column_name: str) -> bool:
    inspector = sa.inspect(bind)
    columns = inspector.get_columns(table_name)
    return any(column["name"] == column_name for column in columns)


def _create_job_status_enum_if_needed(bind) -> None:
    if bind.dialect.name != "postgresql":
        return

    op.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (
                SELECT 1
                FROM pg_type
                WHERE typname = 'job_status'
            ) THEN
                CREATE TYPE job_status AS ENUM (
                    'PENDING',
                    'PROCESSING',
                    'COMPLETED',
                    'FAILED',
                    'COMPLETED_WEBHOOK_FAILED'
                );
            END IF;
        END
        $$;
        """
    )


def upgrade() -> None:
    """Upgrade schema."""
    bind = op.get_bind()

    if not _table_exists(bind, "jobs"):
        if bind.dialect.name == "postgresql":
            _create_job_status_enum_if_needed(bind)
            status_type = postgresql.ENUM(*JOB_STATUS_VALUES, name="job_status", create_type=False)
        else:
            status_type = sa.Enum(*JOB_STATUS_VALUES, name="job_status")

        op.create_table(
            "jobs",
            sa.Column("id", sa.UUID(), nullable=False),
            sa.Column("status", status_type, nullable=False),
            sa.Column("operations", sa.JSON(), nullable=False),
            sa.Column("result_urls", sa.JSON(), nullable=True),
            sa.Column("result_keys", sa.JSON(), nullable=True),
            sa.Column("exif_metadata", sa.JSON(), nullable=True),
            sa.Column("webhook_url", sa.String(length=2048), nullable=False),
            sa.Column("s3_raw_key", sa.String(length=512), nullable=False),
            sa.Column("original_filename", sa.String(length=255), nullable=True),
            sa.Column("error_message", sa.Text(), nullable=True),
            sa.Column("retry_count", sa.Integer(), nullable=False),
            sa.Column(
                "created_at",
                sa.DateTime(timezone=True),
                server_default=sa.text("(CURRENT_TIMESTAMP)"),
                nullable=False,
            ),
            sa.Column(
                "updated_at",
                sa.DateTime(timezone=True),
                server_default=sa.text("(CURRENT_TIMESTAMP)"),
                nullable=False,
            ),
            sa.PrimaryKeyConstraint("id"),
        )

    if _table_exists(bind, "jobs") and not _index_exists(bind, "jobs", op.f("ix_jobs_status")):
        op.create_index(op.f("ix_jobs_status"), "jobs", ["status"], unique=False)

    if _table_exists(bind, "jobs") and not _column_exists(bind, "jobs", "result_keys"):
        op.add_column("jobs", sa.Column("result_keys", sa.JSON(), nullable=True))
    if _table_exists(bind, "jobs") and not _column_exists(bind, "jobs", "exif_metadata"):
        op.add_column("jobs", sa.Column("exif_metadata", sa.JSON(), nullable=True))


def downgrade() -> None:
    """Downgrade schema."""
    bind = op.get_bind()

    if _table_exists(bind, "jobs"):
        if _index_exists(bind, "jobs", op.f("ix_jobs_status")):
            op.drop_index(op.f("ix_jobs_status"), table_name="jobs")
        op.drop_table("jobs")

    if bind.dialect.name == "postgresql":
        op.execute("DROP TYPE IF EXISTS job_status")
