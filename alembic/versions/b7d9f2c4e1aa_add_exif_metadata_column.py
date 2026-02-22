"""Add exif_metadata column to jobs

Revision ID: b7d9f2c4e1aa
Revises: aec75fc63a2f
Create Date: 2026-02-22 02:10:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "b7d9f2c4e1aa"
down_revision: Union[str, Sequence[str], None] = "aec75fc63a2f"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _table_exists(bind, table_name: str) -> bool:
    inspector = sa.inspect(bind)
    return table_name in inspector.get_table_names()


def _column_exists(bind, table_name: str, column_name: str) -> bool:
    inspector = sa.inspect(bind)
    columns = inspector.get_columns(table_name)
    return any(column["name"] == column_name for column in columns)


def upgrade() -> None:
    """Upgrade schema."""
    bind = op.get_bind()
    if _table_exists(bind, "jobs") and not _column_exists(bind, "jobs", "exif_metadata"):
        op.add_column("jobs", sa.Column("exif_metadata", sa.JSON(), nullable=True))


def downgrade() -> None:
    """Downgrade schema."""
    bind = op.get_bind()
    if _table_exists(bind, "jobs") and _column_exists(bind, "jobs", "exif_metadata"):
        op.drop_column("jobs", "exif_metadata")
