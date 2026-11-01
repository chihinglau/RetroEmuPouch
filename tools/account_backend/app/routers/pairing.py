from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from ..database import get_db
from ..dependencies import get_current_user
from ..models import User
from ..schemas.pairing import *
from ..services import pairing_service

router = APIRouter(prefix="/api/pairing", tags=["pairing"])


@router.post("/register", response_model=PairingRegisterResponse)
def register_pairing(
    req: PairingRegisterRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    pairing, token = pairing_service.register_pairing(
        db, current_user, req.pc_name, req.pc_mac_hash
    )
    return PairingRegisterResponse(ok=True, pc_access_token=token)


@router.get("/list", response_model=PairingListResponse)
def list_pairings(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    pairings = pairing_service.list_pairings(db, current_user)
    return PairingListResponse(
        pairings=[
            PairingItem(
                id=p.id,
                pc_name=p.pc_name,
                pc_mac_hash=p.pc_mac_hash[:16] + "..." if len(p.pc_mac_hash) > 16 else p.pc_mac_hash,
                last_seen_at=p.last_seen_at.isoformat() if p.last_seen_at else None,
                created_at=p.created_at.isoformat(),
            )
            for p in pairings
        ]
    )


@router.delete("/{pairing_id}")
def delete_pairing(
    pairing_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    pairing_service.delete_pairing(db, current_user, pairing_id)
    return {"ok": True}
